// SPDX-License-Identifier: MPL-2.0
// Crop the existing WebView2 PNG using the OS-provided Windows Imaging Component.
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <wincodec.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { hr = (expr); if (FAILED(hr)) goto cleanup; } while (0)
HRESULT turf_crop_png(const BYTE *input, UINT length, int x, int y, int width, int height,
                     BYTE **output, UINT *output_length) {
    HRESULT hr = E_FAIL;
    IWICImagingFactory *factory = NULL;
    IWICStream *source = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapFrameDecode *frame = NULL;
    IWICBitmapClipper *clipper = NULL;
    IWICBitmapEncoder *encoder = NULL;
    IWICBitmapFrameEncode *encoded = NULL;
    IStream *destination = NULL;
    HGLOBAL storage = NULL;
    STATSTG stat;
    UINT image_width, image_height;
    WICRect region = {x,y,width,height};
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    *output = NULL; *output_length = 0;
    CHECK(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
                           &IID_IWICImagingFactory, (void **)&factory));
    CHECK(IWICImagingFactory_CreateStream(factory, &source));
    CHECK(IWICStream_InitializeFromMemory(source, (BYTE *)input, length));
    CHECK(IWICImagingFactory_CreateDecoderFromStream(factory, (IStream *)source, NULL,
                                                    WICDecodeMetadataCacheOnLoad, &decoder));
    CHECK(IWICBitmapDecoder_GetFrame(decoder, 0, &frame));
    CHECK(IWICBitmapFrameDecode_GetSize(frame, &image_width, &image_height));
    if (x < 0 || y < 0 || width <= 0 || height <= 0 ||
        (UINT)x > image_width || (UINT)y > image_height ||
        (UINT)width > image_width-(UINT)x || (UINT)height > image_height-(UINT)y) {
        hr = E_INVALIDARG; goto cleanup;
    }
    CHECK(IWICImagingFactory_CreateBitmapClipper(factory, &clipper));
    CHECK(IWICBitmapClipper_Initialize(clipper, (IWICBitmapSource *)frame, &region));
    CHECK(CreateStreamOnHGlobal(NULL, TRUE, &destination));
    CHECK(IWICImagingFactory_CreateEncoder(factory, &GUID_ContainerFormatPng, NULL, &encoder));
    CHECK(IWICBitmapEncoder_Initialize(encoder, destination, WICBitmapEncoderNoCache));
    CHECK(IWICBitmapEncoder_CreateNewFrame(encoder, &encoded, NULL));
    CHECK(IWICBitmapFrameEncode_Initialize(encoded, NULL));
    CHECK(IWICBitmapFrameEncode_SetSize(encoded, width, height));
    CHECK(IWICBitmapFrameEncode_SetPixelFormat(encoded, &format));
    CHECK(IWICBitmapFrameEncode_WriteSource(encoded, (IWICBitmapSource *)clipper, NULL));
    CHECK(IWICBitmapFrameEncode_Commit(encoded));
    CHECK(IWICBitmapEncoder_Commit(encoder));
    CHECK(IStream_Stat(destination, &stat, STATFLAG_NONAME));
    if (stat.cbSize.QuadPart > 24*1024*1024-1024) { hr = E_OUTOFMEMORY; goto cleanup; }
    CHECK(GetHGlobalFromStream(destination, &storage));
    void *bytes = GlobalLock(storage);
    if (!bytes) { hr = E_OUTOFMEMORY; goto cleanup; }
    *output_length = (UINT)stat.cbSize.QuadPart;
    *output = malloc(*output_length);
    if (*output) memcpy(*output, bytes, *output_length);
    else hr = E_OUTOFMEMORY;
    GlobalUnlock(storage);
cleanup:
    if (encoded) IWICBitmapFrameEncode_Release(encoded);
    if (encoder) IWICBitmapEncoder_Release(encoder);
    if (destination) IStream_Release(destination);
    if (clipper) IWICBitmapClipper_Release(clipper);
    if (frame) IWICBitmapFrameDecode_Release(frame);
    if (decoder) IWICBitmapDecoder_Release(decoder);
    if (source) IWICStream_Release(source);
    if (factory) IWICImagingFactory_Release(factory);
    return hr;
}
void turf_free_png(void *bytes) { free(bytes); }
