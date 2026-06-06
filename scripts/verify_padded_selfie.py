#!/usr/bin/env python3
"""
Tests the SELFIE path: a tight crop (face fills frame) goes through pad -> SCRFD
detect -> map kps back -> warpAligned. Does that embedding match the same face
aligned normally? If not, the selfie anchor is garbage and every library face
scores ~0 against it (which is what the device shows).
"""
import cv2, numpy as np, torch, coremltools as ct
from pathlib import Path
import adaface_net as net
import insightface
from insightface.app import FaceAnalysis
from insightface.utils import face_align

SCRIPT=Path(__file__).parent
m=net.build_model("ir_101")
sd=torch.load(str(SCRIPT/"adaface_ir101_webface12m.ckpt"),map_location="cpu")["state_dict"]
m.load_state_dict({k[6:]:v for k,v in sd.items() if k.startswith("model.")}); m.eval()
def embed(a):
    t=(a.astype(np.float32)-127.5)/127.5
    t=torch.from_numpy(np.ascontiguousarray(t.transpose(2,0,1))[None])
    with torch.no_grad(): f=m(t)[0][0].numpy()
    return f/(np.linalg.norm(f)+1e-9)
def cos(a,b): return float(np.dot(a,b))

ml=ct.models.MLModel(str(SCRIPT/"SCRFD10G.mlpackage")); inname=ml.get_spec().description.input[0].name
STRIDES=[8,16,32]
def anchors(s):
    hw=640//s; ac=np.stack(np.mgrid[:hw,:hw][::-1],axis=-1).astype(np.float32)
    ac=(ac*s).reshape(-1,2); return np.stack([ac,ac],axis=1).reshape(-1,2)
AC={s:anchors(s) for s in STRIDES}
def scrfd_detect(bgr,thr=0.5):
    rgb=cv2.cvtColor(bgr,cv2.COLOR_BGR2RGB); h,w=rgb.shape[:2]; S=640; scale=min(S/w,S/h)
    nw,nh=min(S,round(w*scale)),min(S,round(h*scale))
    canvas=np.zeros((S,S,3),np.float32); canvas[:nh,:nw]=cv2.resize(rgb,(nw,nh))
    blob=((canvas-127.5)/128).transpose(2,0,1)[None].astype(np.float32)
    out=ml.predict({inname:blob}); res=[]
    def pick(L,inner):
        for k,v in out.items():
            a=np.array(v)
            if a.shape[0]==L and a.shape[1]==inner: return a
    for s in STRIDES:
        L=(640//s)**2*2; sc=pick(L,1)[:,0]; kp=pick(L,10)*s; ac=AC[s]
        for i in np.where(sc>=thr)[0]:
            pts=[[ac[i,0]+kp[i,j*2], ac[i,1]+kp[i,j*2+1]] for j in range(5)]
            res.append((sc[i], np.array(pts,np.float32)/scale))
    return sorted(res,key=lambda r:-r[0])

ARCFACE_DST=np.array([[38.2946,51.6963],[73.5318,51.5014],[56.0252,71.7366],
                      [41.5493,92.3655],[70.7299,92.2041]],np.float32)
def warp_aligned(bgr,kps):
    ata=np.zeros((4,4)); atb=np.zeros(4)
    for i in range(5):
        sx,sy=kps[i]; dx,dy=ARCFACE_DST[i]
        for row,d in (([sx,-sy,1,0],dx),([sy,sx,0,1],dy)):
            row=np.array(row,float); ata+=np.outer(row,row); atb+=row*d
    a,b,tx,ty=np.linalg.solve(ata,atb); det=a*a+b*b
    out=np.zeros((112,112,3),np.uint8); H,W=bgr.shape[:2]
    for oy in range(112):
        for ox in range(112):
            sx=(a*(ox-tx)+b*(oy-ty))/det; sy=(-b*(ox-tx)+a*(oy-ty))/det
            if sx<0 or sy<0 or sx>=W-1 or sy>=H-1: continue
            x0,y0=int(sx),int(sy); fx,fy=sx-x0,sy-y0
            for c in range(3):
                out[oy,ox,c]=min(max(int(bgr[y0,x0,c]*(1-fx)*(1-fy)+bgr[y0,x0+1,c]*fx*(1-fy)+
                    bgr[y0+1,x0,c]*(1-fx)*fy+bgr[y0+1,x0+1,c]*fx*fy),0),255)
    return out

app=FaceAnalysis(name="buffalo_l",allowed_modules=["detection"]); app.prepare(ctx_id=-1,det_size=(640,640))
img=insightface.data.get_image("t1")
f=sorted(app.get(img),key=lambda f:f.bbox[0])[0]
ref=embed(face_align.norm_crop(img,f.kps))     # the face aligned normally (reference)

# tight crop: face fills the frame, like the selfie
x1,y1,x2,y2=[int(v) for v in f.bbox]
tight=img[max(0,y1):y2, max(0,x1):x2]

# SELFIE PATH: pad -> detect -> map kps back -> warpAligned on the tight crop
mw,mh=tight.shape[1]*2//5, tight.shape[0]*2//5
padded=cv2.copyMakeBorder(tight,mh,mh,mw,mw,cv2.BORDER_CONSTANT,value=0)
det=scrfd_detect(padded)
print(f"padded detect found {len(det)} face(s)")
if det:
    kps_padded=det[0][1]
    kps_tight=kps_padded - np.array([mw,mh],np.float32)   # map back (Swift subtracts margin)
    sel=embed(warp_aligned(tight,kps_tight))
    print(f"cos(selfie-path embedding, normal embedding) = {cos(ref,sel):.3f}   -- should be ~0.9+")
