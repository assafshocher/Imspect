from __future__ import annotations
import io
import json
import math
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from imspect import engine as e

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = json.loads((ROOT / "Tests/resize-fixtures.json").read_text())


def rgba(value=.5, h=16, w=18):
    a = np.full((h,w,4),value,np.float32)
    a[...,3] = 1
    return a


@pytest.mark.parametrize("case",FIXTURES,ids=[x["name"] for x in FIXTURES])
def test_original_resizeright_fixtures(case):
    src = np.asarray(case["input"],np.float32).reshape(case["input_height"],case["input_width"],4)
    expected = np.asarray(case["expected"],np.float64).reshape(case["height"],case["width"],4)
    got = e.resize(src,case["width"],case["height"],case["kernel"],case["scale_x"],case["scale_y"],case["boundary"])
    np.testing.assert_allclose(got[...,:3],expected[...,:3],atol=3e-6,rtol=3e-6)
    assert np.all(got[...,3]==1)  # Native policy: opaque constant padding remains opaque.


def test_known_metrics_and_population_ssim():
    a,b = rgba(0),rgba(1)
    result=e.metrics(a,b)
    assert result["mse"]==1 and result["psnr"]==0 and result["histogram"]==1
    assert result["ssim"] == pytest.approx(.0001/1.0001,abs=2e-9)
    assert result["delta_e"] == pytest.approx(100,abs=3e-5)
    same=e.metrics(a,a)
    assert same["mse"]==0 and math.isinf(same["psnr"]) and same["ssim"]==1
    assert same["delta_e"]==0 and same["histogram"]==0


def test_ssim_independent_direct_two_dimensional_reference():
    rng=np.random.default_rng(9)
    a=rgba(h=13,w=14); a[...,:3]=rng.random((13,14,3))
    b=a.copy(); b[6,7,:3]=.1
    expected=[]
    y,x=np.mgrid[-5:6,-5:6]
    window=np.exp(-(x*x+y*y)/(2*1.5**2)); window/=window.sum()
    for row in range(5,8):
        for col in range(5,9):
            channels=[]
            for c in range(3):
                p=a[row-5:row+6,col-5:col+6,c].astype(float)
                q=b[row-5:row+6,col-5:col+6,c].astype(float)
                u=(p*window).sum(); v=(q*window).sum()
                vp=((p-u)**2*window).sum(); vq=((q-v)**2*window).sum()
                cv=((p-u)*(q-v)*window).sum()
                channels.append(((2*u*v+.0001)*(2*cv+.0009))/((u*u+v*v+.0001)*(vp+vq+.0009)))
            expected.append(np.mean(channels))
    np.testing.assert_allclose(e.ssim_map(a,b).ravel(),expected,atol=8e-8)


def test_metric_validation_and_roi():
    a=rgba()
    for bad in [rgba(h=15),rgba(value=1.1)]:
        with pytest.raises(ValueError): e.metrics(a,bad)
    transparent=a.copy(); transparent[0,0,3]=.4
    with pytest.raises(ValueError,match="opaque"): e.metrics(a,transparent)
    assert e.metrics(a,transparent,(1,1,5,5))["mse"]==0
    assert e.metrics(a,a,(1,1,5,5))["ssim"] is None
    for roi in [(-1,0,2,2),(0,0,100,100),(0,0,0,2),(0.,0,1,1)]:
        with pytest.raises(ValueError): e.metrics(a,a,roi)


def test_viewport_identity_and_adjacent_patch_consistency():
    rng=np.random.default_rng(5)
    a=rgba(h=19,w=21); a[...,:3]=rng.random((19,21,3))
    for kernel in e.KERNELS:
        np.testing.assert_allclose(e.render_patch(a,(0,0),1,21,19,kernel),a,atol=2e-6)
        whole=e.render_patch(a,(2.3,1.7),3.6,37,29,kernel)
        first=e.render_patch(a,(2.3,1.7),3.6,15,29,kernel)
        second=e.render_patch(a,(2.3+15/3.6,1.7),3.6,22,29,kernel)
        np.testing.assert_allclose(np.concatenate((first,second),axis=1),whole,atol=3e-6)
    out=e.render_patch(a,(-2,-3),1,25,25)
    assert np.all(out[:3,:,3]==0) and np.all(out[:,:2,3]==0)
    np.testing.assert_allclose(out[3:22,2:23],a,atol=2e-6)


def test_visible_kernel_changes_and_no_transparent_fringe():
    a=rgba(h=3,w=3); a[:,:,:3]=0; a[1,1,:3]=1
    nearest=e.render_patch(a,(0,0),4,12,12,"nearest")
    cubic=e.render_patch(a,(0,0),4,12,12,"cubic")
    assert np.max(np.abs(nearest-cubic))>.1
    a[0,0]=[1,0,0,0]
    result=e.resize(a,19,19,"linear")
    # Invisible red sample cannot leak a red-only fringe into reconstruction.
    np.testing.assert_allclose(result[...,0],result[...,1],atol=1e-7)


def test_fft_shared_scale_and_map_borders():
    a=rgba(1,h=16,w=16)
    fft=e.derived(a,None,"fft")
    assert fft.shape==(16,16,4)
    assert fft[8,8,0]==pytest.approx(1)
    assert np.count_nonzero(fft[...,0]>.0001)==1
    heat=e.derived(a,a,"ssim")
    assert np.all(heat[:5,:,3]==0) and np.all(heat[5:-5,5:-5,3]==1)
    np.testing.assert_allclose(heat[5:-5,5:-5,:3],np.broadcast_to([.015,.01,.06],(6,6,3)),atol=1e-6)


def test_histograms_and_channel_landmarks():
    a=rgba(.25)
    hist=e.histogram(a)
    np.testing.assert_allclose(hist.sum(axis=1),1)
    assert np.all(hist[:,64]==1)
    out=e.channel_adjust(a,[-1,0,1])
    assert np.all(out[...,0]==0) and np.all(out[...,1]==a[...,1]) and np.all(out[...,2]==1)
    np.testing.assert_array_equal(e.channel_adjust(a,[0,0,0]),a)
    with pytest.raises(ValueError): e.channel_adjust(a,[2,0,0])


def test_noise_matches_native_splitmix64_and_is_repeatable():
    a=rgba(.5,h=2,w=2)
    state=42; expected=[]; mask=(1<<64)-1
    def uniform():
        nonlocal state
        state=(state+0x9E3779B97F4A7C15)&mask
        z=state; z=((z^(z>>30))*0xBF58476D1CE4E5B9)&mask
        z=((z^(z>>27))*0x94D049BB133111EB)&mask; z^=z>>31
        return ((z>>11)+.5)/9007199254740992
    for _ in range(12):
        value=np.float32(math.sqrt(-2*math.log(uniform()))*math.cos(2*math.pi*uniform()))
        expected.append(np.clip(np.float32(.5)+np.float32(.1)*value,0,1))
    got=e.apply_edit(a,"noise",.1,42)
    np.testing.assert_allclose(got[...,:3].ravel(),expected,atol=1e-7)
    np.testing.assert_array_equal(got,e.apply_edit(a,"noise",.1,42))


def test_filters_restore_constants_and_reduce_noise():
    a=rgba(.4,h=32,w=32)
    for kind,amount in [("gaussian",2),("bilateral",.1),("sharpen",1)]:
        np.testing.assert_allclose(e.apply_edit(a,kind,amount),a,atol=2e-6)
    noisy=e.apply_edit(a,"noise",.06,3)
    smoothed=e.apply_edit(noisy,"bilateral",.15)
    assert e.metrics(a,smoothed)["mse"] < e.metrics(a,noisy)["mse"]
    np.testing.assert_array_equal(e.apply_edit(a,"match_histogram",reference=a),a)
    transparent=a.copy(); transparent[...,3]=0
    assert np.all(e.apply_edit(transparent,"white")==1)
    assert np.all(e.apply_edit(transparent,"black")[...,:3]==0)


def test_16bit_png_roundtrip_and_8bit_import(tmp_path):
    a=rgba(h=7,w=9)
    a[:,:,:3]=np.linspace(0,1,7*9*3).reshape(7,9,3)
    a[...,3]=.3
    path=tmp_path/"samples.png"; e.save_png(a,path)
    assert path.read_bytes()[24]==16
    np.testing.assert_allclose(e.load_image(path),a,atol=1/65535)
    im=Image.fromarray(np.uint8([[[100,150,200,127]]]))
    im.save(tmp_path/"8.png")
    np.testing.assert_allclose(e.load_image(tmp_path/"8.png"),np.asarray(im,dtype=np.float32)/255)


def test_demo_and_invalid_inputs():
    data=e.demo_images()
    assert len(data)==3 and len({a.shape for _,a in data})==1
    for _,a in data: e.validate_image(a)
    with pytest.raises(ValueError): e.resize(rgba(),0,1)
    with pytest.raises(ValueError): e.render_patch(rgba(),(0,0),0,10,10)
    with pytest.raises(ValueError): e.derived(rgba(),None,"mse")
    with pytest.raises(ValueError): e.apply_edit(rgba(),"noise",2)
    bad=rgba(); bad[0,0,0]=np.nan
    with pytest.raises(ValueError): e.metrics(bad,bad)


def test_identity_resize_is_exact_for_every_kernel():
    a=rgba(h=9,w=11)
    a[...,:3]=np.random.default_rng(22).random((9,11,3),dtype=np.float32)
    for kernel in e.KERNELS:
        np.testing.assert_array_equal(e.resize(a,11,9,kernel),a)
