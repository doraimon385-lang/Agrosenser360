"""AgroSenser360 - API. Inicio: uvicorn main:app --host 0.0.0.0 --port $PORT"""
import base64, io
from datetime import date, timedelta

import numpy as np
import rasterio
from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel, Field
from pyproj import Transformer
from pystac_client import Client
from rasterio.crs import CRS
from rasterio.enums import Resampling
from rasterio.features import geometry_mask, shapes
from rasterio.transform import from_origin
from rasterio.vrt import WarpedVRT
from shapely.geometry import mapping, shape
from shapely.ops import transform as shp_transform

STAC_URL = "https://earth-search.aws.element84.com/v1"
RES = 10
SCL_INVALID = (0, 1, 3, 6, 8, 9, 10, 11)  # sin datos, saturado, sombra, agua, nubes, cirro, nieve
NODATA, OK, WATCH, INSPECT = 255, 0, 1, 2
LABELS = {OK: "normal", WATCH: "vigilar", INSPECT: "inspeccionar"}
MAX_HA = 1000

app = FastAPI(title="AgroSenser360 API", version="0.2.0")


# ---------- Análisis ----------
def compute_ndvi(red, nir):
    den = nir + red
    with np.errstate(divide="ignore", invalid="ignore"):
        v = (nir - red) / den
    v[den == 0] = np.nan
    return np.clip(v, -1, 1)


def classify(ndvi, previous=None):
    """z-score frente al lote + caída frente a la fecha anterior."""
    valid = np.isfinite(ndvi)
    cls = np.full(ndvi.shape, NODATA, dtype="uint8")
    if valid.sum() < 2:
        return cls
    cls[valid] = OK
    std = np.nanstd(ndvi)
    if std > 1e-6:
        z = (ndvi - np.nanmean(ndvi)) / std
        cls[valid & (z <= -1.0)] = WATCH
        cls[valid & (z <= -1.5)] = INSPECT
    if previous is not None:
        drop = previous - ndvi
        both = valid & np.isfinite(previous)
        cls[both & (drop >= 0.10) & (cls < WATCH)] = WATCH
        cls[both & (drop >= 0.20)] = INSPECT
    return cls


# ---------- Sentinel-2 ----------
class Grid:
    def __init__(self, geom, epsg):
        self.crs = CRS.from_epsg(epsg)
        self.to_wgs = Transformer.from_crs(self.crs, 4326, always_xy=True).transform
        self.geom = shp_transform(Transformer.from_crs(4326, epsg, always_xy=True).transform, geom)
        minx, miny, maxx, maxy = self.geom.bounds
        x0, y1 = np.floor(minx / RES) * RES, np.ceil(maxy / RES) * RES
        self.w, self.h = int(np.ceil((maxx - x0) / RES)), int(np.ceil((y1 - miny) / RES))
        self.tr = from_origin(x0, y1, RES, RES)
        self.inside = ~geometry_mask([self.geom], (self.h, self.w), self.tr)


def read_band(asset, grid, scale=True):
    rb = (asset.extra_fields.get("raster:bands") or [{}])[0]
    with rasterio.open(asset.href) as src, WarpedVRT(
        src, crs=grid.crs, transform=grid.tr, width=grid.w, height=grid.h,
        resampling=Resampling.nearest) as vrt:
        a = vrt.read(1).astype("float32")
    return (a + rb.get("offset", 0)) * rb.get("scale", 1e-4) if scale else a


def item_epsg(item):
    v = item.properties.get("proj:code") or item.properties.get("proj:epsg")
    return int(str(v).replace("EPSG:", ""))


def ndvi_of(item, grid):
    red, nir = read_band(item.assets["red"], grid), read_band(item.assets["nir"], grid)
    scl = read_band(item.assets["scl"], grid, scale=False)
    ndvi = compute_ndvi(red, nir)
    ndvi[np.isin(scl, SCL_INVALID) | ~grid.inside] = np.nan
    return ndvi, float(np.isfinite(ndvi).sum() / max(grid.inside.sum(), 1))


def pick_scenes(items, grid, min_valid=0.6, gap_days=5):
    cur = prev = None
    for it in items[:12]:
        if cur and (cur[0].datetime - it.datetime).days < gap_days:
            continue
        ndvi, frac = ndvi_of(it, grid)
        if frac < min_valid:
            continue
        if cur is None:
            cur = (it, ndvi)
        else:
            prev = (it, ndvi)
            break
    return cur, prev


# ---------- Salidas ----------
STOPS = [(-0.1, (165, 0, 38)), (0.2, (244, 109, 67)), (0.4, (254, 224, 139)),
         (0.6, (102, 189, 99)), (0.9, (0, 104, 55))]


def png_b64(ndvi):
    xs = [s[0] for s in STOPS]
    rgba = np.zeros((*ndvi.shape, 4), dtype="uint8")
    filled = np.nan_to_num(ndvi, nan=-1)
    for ch in range(3):
        rgba[..., ch] = np.interp(filled, xs, [s[1][ch] for s in STOPS])
    rgba[..., 3] = np.where(np.isfinite(ndvi), 200, 0)
    buf = io.BytesIO()
    Image.fromarray(rgba, "RGBA").save(buf, "PNG")
    return base64.b64encode(buf.getvalue()).decode()


def zones_geojson(cls, grid):
    feats = []
    for g, val in shapes(cls, mask=(cls == WATCH) | (cls == INSPECT), transform=grid.tr):
        poly = shape(g)
        if poly.area < 2 * RES * RES:
            continue
        c = poly.centroid
        lon, lat = grid.to_wgs(c.x, c.y)
        feats.append({"type": "Feature",
                      "geometry": mapping(shp_transform(grid.to_wgs, poly)),
                      "properties": {"priority": LABELS[int(val)], "level": int(val),
                                     "area_ha": round(poly.area / 1e4, 4), "center": [lon, lat]}})
    feats.sort(key=lambda f: (-f["properties"]["level"], -f["properties"]["area_ha"]))
    return {"type": "FeatureCollection", "features": feats}


def bounds_wgs(grid):
    minx, miny = grid.tr * (0, grid.h)
    maxx, maxy = grid.tr * (grid.w, 0)
    (w, s), (e, n) = grid.to_wgs(minx, miny), grid.to_wgs(maxx, maxy)
    return {"west": w, "south": s, "east": e, "north": n}


# ---------- Endpoints ----------
class AnalyzeRequest(BaseModel):
    geometry: dict = Field(..., description="Polígono GeoJSON (WGS84)")
    days: int = 60
    max_cloud: int = 70


@app.get("/")
@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/analyze")
def analyze(req: AnalyzeRequest):
    try:
        geom = shape(req.geometry)
    except Exception:
        raise HTTPException(422, "Geometría inválida")
    if geom.geom_type != "Polygon" or not geom.is_valid:
        raise HTTPException(422, "Se requiere un polígono válido (sin lados cruzados)")

    today = date.today()
    items = Client.open(STAC_URL).search(
        collections=["sentinel-2-l2a"], intersects=geom.__geo_interface__,
        datetime=f"{today - timedelta(days=req.days)}/{today}",
        query={"eo:cloud_cover": {"lt": req.max_cloud}}).item_collection()
    items = sorted(items, key=lambda i: i.datetime, reverse=True)
    if not items:
        raise HTTPException(404, "No hay imágenes Sentinel-2 en ese rango. Amplía los días.")

    grid = Grid(geom, item_epsg(items[0]))
    area_ha = grid.geom.area / 1e4
    if area_ha > MAX_HA:
        raise HTTPException(422, f"La finca supera {MAX_HA} ha")
    if grid.inside.sum() < 4:
        raise HTTPException(422, "Finca demasiado pequeña para resolución de 10 m")

    cur, prev = pick_scenes(items, grid)
    if cur is None:
        raise HTTPException(404, "Las imágenes disponibles tienen demasiadas nubes sobre la finca.")
    item, ndvi = cur
    cls = classify(ndvi, prev[1] if prev else None)
    ha = lambda k: round(float((cls == k).sum()) * RES * RES / 1e4, 3)
    return {
        "scene_date": item.datetime.date().isoformat(),
        "previous_date": prev[0].datetime.date().isoformat() if prev else None,
        "area_ha": round(area_ha, 2),
        "ndvi_mean": round(float(np.nanmean(ndvi)), 3),
        "ha": {LABELS[k]: ha(k) for k in LABELS},
        "zones": zones_geojson(cls, grid),
        "ndvi_png_base64": png_b64(ndvi),
        "bounds": bounds_wgs(grid),
  }
