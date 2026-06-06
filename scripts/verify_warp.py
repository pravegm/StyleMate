#!/usr/bin/env python3
"""
Does the app's own warpAligned (similarity transform via normal equations +
inverse bilinear sampling) produce the SAME aligned crop as InsightFace's
norm_crop? Every prior test used norm_crop; the app uses warpAligned, which was
never verified. If these disagree, every embedding is garbage no matter what.
"""
import cv2, numpy as np, torch
from pathlib import Path
import adaface_net as net
import insightface
from insightface.app import FaceAnalysis
from insightface.utils import face_align

SCRIPT = Path(__file__).parent
m = net.build_model("ir_101")
sd = torch.load(str(SCRIPT/"adaface_ir101_webface12m.ckpt"), map_location="cpu")["state_dict"]
m.load_state_dict({k[6:]:v for k,v in sd.items() if k.startswith("model.")}); m.eval()
def embed(a):
    t=(a.astype(np.float32)-127.5)/127.5
    t=torch.from_numpy(np.ascontiguousarray(t.transpose(2,0,1))[None])
    with torch.no_grad(): f=m(t)[0][0].numpy()
    return f/(np.linalg.norm(f)+1e-9)
def cos(a,b): return float(np.dot(a,b))

ARCFACE_DST = np.array([[38.2946,51.6963],[73.5318,51.5014],[56.0252,71.7366],
                        [41.5493,92.3655],[70.7299,92.2041]], dtype=np.float32)

def warp_aligned(img_bgr, kps):
    """Faithful port of the Swift warpAligned: solve [a,-b,tx;b,a,ty] over 5 pts
    via normal equations, then inverse-bilinear-sample into 112x112."""
    ata=np.zeros((4,4),np.float64); atb=np.zeros(4,np.float64)
    for i in range(5):
        sx,sy=kps[i]; dx,dy=ARCFACE_DST[i]
        for row,d in (([sx,-sy,1,0],dx),([sy,sx,0,1],dy)):
            row=np.array(row,np.float64)
            ata+=np.outer(row,row); atb+=row*d
    a,b,tx,ty=np.linalg.solve(ata,atb)
    det=a*a+b*b;
    out=np.zeros((112,112,3),np.uint8)
    H,W=img_bgr.shape[:2]
    for oy in range(112):
        for ox in range(112):
            dxo=ox-tx; dyo=oy-ty
            sx=(a*dxo+b*dyo)/det; sy=(-b*dxo+a*dyo)/det
            if sx<0 or sy<0 or sx>=W-1 or sy>=H-1: continue
            x0,y0=int(sx),int(sy); fx,fy=sx-x0,sy-y0
            for c in range(3):
                v=(img_bgr[y0,x0,c]*(1-fx)*(1-fy)+img_bgr[y0,x0+1,c]*fx*(1-fy)+
                   img_bgr[y0+1,x0,c]*(1-fx)*fy+img_bgr[y0+1,x0+1,c]*fx*fy)
                out[oy,ox,c]=min(max(int(v),0),255)
    return out

app=FaceAnalysis(name="buffalo_l",allowed_modules=["detection"]); app.prepare(ctx_id=-1,det_size=(640,640))
img=insightface.data.get_image("t1")
faces=sorted(app.get(img), key=lambda f:f.bbox[0])
print("face | cos(norm_crop, warpAligned)  -- should be ~1.0")
for i,f in enumerate(faces):
    nc=face_align.norm_crop(img, f.kps)        # insightface alignment (BGR)
    wa=warp_aligned(img, f.kps)                # the app's alignment (BGR)
    c=cos(embed(nc), embed(wa))
    print(f"  {i}: {c:.3f}")
