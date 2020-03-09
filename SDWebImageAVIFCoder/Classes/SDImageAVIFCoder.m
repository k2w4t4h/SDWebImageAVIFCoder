//
//  SDImageAVIFCoder.m
//  SDWebImageHEIFCoder
//
//  Created by lizhuoli on 2018/5/8.
//

#import "SDImageAVIFCoder.h"
#import <Accelerate/Accelerate.h>
#if __has_include(<libavif/avif.h>)
#import <libavif/avif.h>
#else
#import "avif/avif.h"
#endif

static void FreeImageData(void *info, const void *data, size_t size) {
    free((void *)data);
}

static CGImageRef CreateImageFromBuffer(avifImage * avif, vImage_Buffer* result) {
    BOOL monochrome = avif->yuvPlanes[1] == NULL || avif->yuvPlanes[2] == NULL;
    BOOL hasAlpha = avif->alphaPlane != NULL;
    BOOL usesU16 = avifImageUsesU16(avif);
    size_t components = (monochrome ? 1 : 3) + (hasAlpha ? 1 : 0);

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, result->data, result->rowBytes * result->height, FreeImageData);
    CGBitmapInfo bitmapInfo = usesU16 ? kCGBitmapByteOrder16Host : kCGBitmapByteOrderDefault;
    bitmapInfo |= hasAlpha ? kCGImageAlphaFirst : kCGImageAlphaNone;
    // FIXME: (ledyba-z): Set appropriate color space.
    //  use avif->nclx.colourPrimaries and avif->nclx.transferCharacteristics to detect appropriate color space.
    CGColorSpaceRef colorSpace = NULL;
    if(monochrome){
        colorSpace = CGColorSpaceCreateDeviceGray();
    }else{
        colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    CGColorRenderingIntent renderingIntent = kCGRenderingIntentDefault;
    
    size_t bitsPerComponent = usesU16 ? 16 : 8;
    size_t bitsPerPixel = components * bitsPerComponent;
    size_t rowBytes = result->width * components * (usesU16 ? sizeof(uint16_t) : sizeof(uint8_t));

    CGImageRef imageRef = CGImageCreate(result->width, result->height, bitsPerComponent, bitsPerPixel, rowBytes, colorSpace, bitmapInfo, provider, NULL, NO, renderingIntent);
    
    // clean up
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    
    return imageRef;
}

static void SetupConversionInfo(avifImage * avif,
                                avifReformatState* state,
                                vImage_YpCbCrToARGBMatrix* matrix,
                                vImage_YpCbCrPixelRange* pixelRange) {
    avifPrepareReformatState(avif, state);

    // Setup Matrix
    matrix->Yp = 1.0f;

    matrix->Cb_B =  2.0f * (1.0f - state->kb);
    matrix->Cb_G = -2.0f * (1.0f - state->kb) * state->kb / state->kg;

    matrix->Cr_R =  2.0f * (1.0f - state->kr);
    matrix->Cr_G = -2.0f * (1.0f - state->kr) * state->kr / state->kg;

    // Setup Pixel Range
    switch (avif->depth) {
        case 8:
            if (avif->yuvRange == AVIF_RANGE_LIMITED) {
                pixelRange->Yp_bias = 16;
                pixelRange->YpRangeMax = 235;
                pixelRange->YpMax = 255;
                pixelRange->YpMin = 0;
                pixelRange->CbCr_bias = 128;
                pixelRange->CbCrRangeMax = 240;
                pixelRange->CbCrMax = 255;
                pixelRange->CbCrMin = 0;
            }else{
                pixelRange->Yp_bias = 0;
                pixelRange->YpRangeMax = 255;
                pixelRange->YpMax = 255;
                pixelRange->YpMin = 0;
                pixelRange->CbCr_bias = 128;
                pixelRange->CbCrRangeMax = 255;
                pixelRange->CbCrMax = 255;
                pixelRange->CbCrMin = 0;
            }
            break;
        case 10:
            if (avif->yuvRange == AVIF_RANGE_LIMITED) {
                pixelRange->Yp_bias = 64;
                pixelRange->YpRangeMax = 940;
                pixelRange->YpMax = 1023;
                pixelRange->YpMin = 0;
                pixelRange->CbCr_bias = 512;
                pixelRange->CbCrRangeMax = 960;
                pixelRange->CbCrMax = 1023;
                pixelRange->CbCrMin = 0;
            }else{
                pixelRange->Yp_bias = 0;
                pixelRange->YpRangeMax = 1023;
                pixelRange->YpMax = 1023;
                pixelRange->YpMin = 0;
                pixelRange->CbCr_bias = 512;
                pixelRange->CbCrRangeMax = 1023;
                pixelRange->CbCrMax = 1023;
                pixelRange->CbCrMin = 0;
            }
            break;
        case 12:
            if (avif->yuvRange == AVIF_RANGE_LIMITED) {
                pixelRange->Yp_bias = 256;
                pixelRange->YpRangeMax = 3760;
                pixelRange->YpMax = 4095;
                pixelRange->YpMin = 0;
                pixelRange->CbCr_bias = 2048;
                pixelRange->CbCrRangeMax = 3840;
                pixelRange->CbCrMax = 4095;
                pixelRange->CbCrMin = 0;
            }else{
                pixelRange->Yp_bias = 0;
                pixelRange->YpRangeMax = 4095;
                pixelRange->YpMax = 4095;
                pixelRange->YpMin = 0;
                pixelRange->CbCr_bias = 2048;
                pixelRange->CbCrRangeMax = 4095;
                pixelRange->CbCrMax = 4095;
                pixelRange->CbCrMin = 0;
            }
            break;
        default:
            NSLog(@"Unknown bit depth: %d", avif->depth);
            return;
    }
    
}


// Convert 8bit AVIF image into RGB888/ARGB8888/Mono/MonoA using vImage Acceralation Framework.
static CGImageRef CreateImage8(avifImage * avif) {
    CGImageRef result = NULL;
    uint8_t* resultBufferData = NULL;
    uint8_t* argbBufferData = NULL;
    uint8_t* dummyCbData = NULL;
    uint8_t* dummyCrData = NULL;

    vImage_Error err = kvImageNoError;

    // image properties
    BOOL const monochrome = avif->yuvPlanes[1] == NULL || avif->yuvPlanes[2] == NULL;
    BOOL const hasAlpha = avif->alphaPlane != NULL;
    size_t const components = (monochrome ? 1 : 3) + (hasAlpha ? 1 : 0);
    size_t const rowBytes = components * sizeof(uint8_t) * avif->width;

    // setup conversion info
    avifReformatState state = {0};
    vImage_YpCbCrToARGBMatrix matrix = {0};
    vImage_YpCbCrPixelRange pixelRange = {0};
    SetupConversionInfo(avif, &state, &matrix, &pixelRange);

    vImage_YpCbCrToARGB convInfo = {0};

    resultBufferData = calloc(components * rowBytes * avif->height, sizeof(uint8_t));
    if(resultBufferData == NULL) {
        goto end_all;
    }
    
    BOOL const useTempBuffer = monochrome || !hasAlpha; // if and only if the image is not ARGB

    if(useTempBuffer) {
        argbBufferData = calloc(avif->width * avif->height * 4, sizeof(uint8_t));
        if(argbBufferData == NULL) {
            goto end_all;
        }
    }

    vImage_Buffer resultBuffer = {
        .data = resultBufferData,
        .width = avif->width,
        .height = avif->height,
        .rowBytes = avif->width * components,
    };
    vImage_Buffer argbBuffer = {
        .data = useTempBuffer ? argbBufferData : resultBufferData,
        .width = avif->width,
        .height = avif->height,
        .rowBytes = avif->width * 4,
    };
    vImage_Buffer origY = {
        .data = avif->yuvPlanes[AVIF_CHAN_Y],
        .rowBytes = avif->yuvRowBytes[AVIF_CHAN_Y],
        .width = avif->width,
        .height = avif->height,
    };

    vImage_Buffer origCb = {
        .data = avif->yuvPlanes[AVIF_CHAN_U],
        .rowBytes = avif->yuvRowBytes[AVIF_CHAN_U],
        .width = (avif->width+state.formatInfo.chromaShiftX) >> state.formatInfo.chromaShiftX,
        .height = (avif->height+state.formatInfo.chromaShiftY) >> state.formatInfo.chromaShiftY,
    };

    if(origCb.data == NULL) { // allocate dummy data to convert monochrome images.
        dummyCbData = calloc(origCb.width, sizeof(uint8_t));
        if(dummyCbData == NULL) {
            goto end_all;
        }
        origCb.data = dummyCbData;
        origCb.rowBytes = 0;
        memset(origCb.data, pixelRange.CbCr_bias, origCb.width);
    }

    vImage_Buffer origCr = {
        .data = avif->yuvPlanes[AVIF_CHAN_V],
        .rowBytes = avif->yuvRowBytes[AVIF_CHAN_V],
        .width = (avif->width+state.formatInfo.chromaShiftX) >> state.formatInfo.chromaShiftX,
        .height = (avif->height+state.formatInfo.chromaShiftY) >> state.formatInfo.chromaShiftY,
    };
    if(origCr.data == NULL) { // allocate dummy data to convert monochrome images.
        dummyCrData = calloc(origCr.width, sizeof(uint8_t));
        if(dummyCrData == NULL) {
            goto end_all;
        }
        origCr.data = dummyCrData;
        origCr.rowBytes = 0;
        memset(origCr.data, pixelRange.CbCr_bias, origCr.width);
    }
    
    //TODO: (ledyba-z) we have to scale alpha when libavif v0.6.0 comes.
    //  https://github.com/AOMediaCodec/libavif/issues/91

    uint8_t const permuteMap[4] = {0, 1, 2, 3};
    switch(avif->yuvFormat) {
        case AVIF_PIXEL_FORMAT_NONE:
            NSLog(@"Invalid pixel format.");
            goto end_all;
        case AVIF_PIXEL_FORMAT_YUV420:
        case AVIF_PIXEL_FORMAT_YV12:
        {
            err =
            vImageConvert_YpCbCrToARGB_GenerateConversion(&matrix,
                                                          &pixelRange,
                                                          &convInfo,
                                                          kvImage420Yp8_Cb8_Cr8,
                                                          kvImageARGB8888,
                                                          kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to setup conversion: %ld", err);
                goto end_420;
            }

            err = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&origY,
                                                         &origCb,
                                                         &origCr,
                                                         &argbBuffer,
                                                         &convInfo,
                                                         permuteMap,
                                                         255,
                                                         kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to convert to ARGB8888: %ld", err);
                goto end_420;
            }
        end_420:
            // We didn't allocate any heaps.
            if(err == kvImageNoError) {
                break;
            } else {
                goto end_all;
            }
        }
        case AVIF_PIXEL_FORMAT_YUV444:
        {
            uint8_t* yuvBufferData = NULL;
            err =
            vImageConvert_YpCbCrToARGB_GenerateConversion(&matrix,
                                                          &pixelRange,
                                                          &convInfo,
                                                          kvImage444CrYpCb8,
                                                          kvImageARGB8888,
                                                          kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to setup conversion: %ld", err);
                goto end_444;
            }

            yuvBufferData = calloc(avif->width * avif->height * 3, sizeof(uint8_t));
            if(yuvBufferData == NULL) {
                err = kvImageMemoryAllocationError;
                goto end_444;
            }
            vImage_Buffer yuvBuffer = {
                .data = yuvBufferData,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->width * 3,
            };
            err = vImageConvert_Planar8toRGB888(&origCr, &origY, &origCb, &yuvBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to composite kvImage444CrYpCb8: %ld", err);
                goto end_444;
            }
            vImageConvert_444CrYpCb8ToARGB8888(&yuvBuffer,
                                               &argbBuffer,
                                               &convInfo,
                                               permuteMap,
                                               255,
                                               kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to convert to ARGB8888: %ld", err);
                goto end_444;
            }
        end_444:
            free(yuvBufferData);
            if(err == kvImageNoError) {
                break;
            } else {
                goto end_all;
            }
        }
        case AVIF_PIXEL_FORMAT_YUV422:
        {
            uint8_t* y1BufferData = NULL;
            uint8_t* y2BufferData = NULL;
            uint8_t* yuyvBufferData = NULL;
            
            err =
            vImageConvert_YpCbCrToARGB_GenerateConversion(&matrix,
                                                          &pixelRange,
                                                          &convInfo,
                                                          kvImage422YpCbYpCr8,
                                                          kvImageARGB8888,
                                                          kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to setup conversion: %ld", err);
                goto end_422;
            }

            const vImagePixelCount alignedWidth = (origY.width+1) & (~1);
            y1BufferData = calloc(alignedWidth/2 * origY.height, sizeof(uint8_t));
            y2BufferData = calloc(alignedWidth/2 * origY.height, sizeof(uint8_t));
            yuyvBufferData = calloc(alignedWidth * avif->height * 2, sizeof(uint8_t));
            if(y1BufferData == NULL || y2BufferData == NULL || yuyvBufferData == NULL) {
                err = kvImageMemoryAllocationError;
                goto end_422;
            }
            vImage_Buffer y1Buffer = {
                .data = y1BufferData,
                .width = alignedWidth/2,
                .height = origY.height,
                .rowBytes = alignedWidth/2 * sizeof(uint8_t),
            };
            vImage_Buffer y2Buffer = {
                .data = y2BufferData,
                .width = alignedWidth/2,
                .height = origY.height,
                .rowBytes = alignedWidth/2 * sizeof(uint8_t),
            };
            vImage_Buffer yuyvBuffer = {
                .data = yuyvBufferData,
                .width = alignedWidth/2, // It will be fixed later.
                .height = avif->height,
                .rowBytes = alignedWidth / 2 * 4 * sizeof(uint8_t),
            };
            err = vImageConvert_ChunkyToPlanar8((const void*[]){origY.data},
                                               (const vImage_Buffer*[]){&y1Buffer},
                                               1 /* channelCount */, 2 /* src srcStrideBytes */,
                                               alignedWidth/2, origY.height,
                                               origY.rowBytes, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to separate first Y channel: %ld", err);
                goto end_422;
            }
            y2Buffer.width = origY.width/2;
            err = vImageConvert_ChunkyToPlanar8((const void*[]){origY.data + 1},
                                               (const vImage_Buffer*[]){&y2Buffer},
                                               1 /* channelCount */, 2 /* src srcStrideBytes */,
                                               origY.width/2, origY.height,
                                               origY.rowBytes, kvImageNoFlags);
            y2Buffer.width = alignedWidth/2;
            if(err != kvImageNoError) {
                NSLog(@"Failed to separate second Y channel: %ld", err);
                goto end_422;
            }
            err = vImageConvert_Planar8toARGB8888(&y1Buffer, &origCb, &y2Buffer, &origCr,
                                                  &yuyvBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to composite kvImage422YpCbYpCr8: %ld", err);
                goto end_422;
            }
            yuyvBuffer.width *= 2;

            err = vImageConvert_422YpCbYpCr8ToARGB8888(&yuyvBuffer,
                                                       &argbBuffer,
                                                       &convInfo,
                                                       permuteMap,
                                                       255,
                                                       kvImageNoFlags);
            if(err != kvImageNoError) {
                goto end_422;
            }
        end_422:
            free(y1BufferData);
            free(y2BufferData);
            free(yuyvBufferData);
            if(err == kvImageNoError) {
                break;
            } else {
                goto end_all;
            }
        }
    }

    if(hasAlpha) { // alpha
        vImage_Buffer alphaBuffer = {
            .data = avif->alphaPlane,
            .width = avif->width,
            .height = avif->height,
            .rowBytes = avif->alphaRowBytes,
        };
        if(monochrome) { // alpha_mono
            uint8_t* tmpBufferData = NULL;
            uint8_t* monoBufferData = NULL;
            tmpBufferData = calloc(avif->width, sizeof(uint8_t));
            monoBufferData = calloc(avif->width * avif->height, sizeof(uint8_t));
            if(tmpBufferData == NULL || monoBufferData == NULL) {
                goto end_alpha_mono;
            }
            vImage_Buffer tmpBuffer = {
                .data = tmpBufferData,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = 0,
            };
            vImage_Buffer monoBuffer = {
                .data = monoBufferData,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->width,
            };
            err = vImageConvert_ARGB8888toPlanar8(&argbBuffer, &tmpBuffer, &tmpBuffer, &monoBuffer, &tmpBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to convert ARGB to A_G_: %ld", err);
                goto end_alpha_mono;
            }
            err = vImageConvert_PlanarToChunky8((const vImage_Buffer*[]){&alphaBuffer, &monoBuffer},
                                                (void*[]){resultBuffer.data, resultBuffer.data + 1},
                                                2 /* channelCount */, 2 /* destStrideBytes */,
                                                resultBuffer.width, resultBuffer.height,
                                                resultBuffer.rowBytes, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to combine mono and alpha: %ld", err);
                goto end_alpha_mono;
            }
            result = CreateImageFromBuffer(avif, &resultBuffer);
            resultBufferData = NULL;
        end_alpha_mono:
            free(tmpBufferData);
            free(monoBufferData);
            goto end_alpha;
        } else { // alpha_color
            err = vImageOverwriteChannels_ARGB8888(&alphaBuffer, &argbBuffer, &argbBuffer, 0x8, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to overwrite alpha: %ld", err);
                goto end_alpha_color;
            }
            result = CreateImageFromBuffer(avif, &argbBuffer);
            resultBufferData = NULL;
        end_alpha_color:
            goto end_alpha;
        }
    end_alpha:
        goto end_all;
    } else { // no_alpha
        if(monochrome) { // no_alpha_mono
            uint8_t* tmpBufferData = NULL;
            tmpBufferData = calloc(avif->width, sizeof(uint8_t));
            if(tmpBufferData == NULL){
                goto end_no_alpha_mono;
            }
            vImage_Buffer tmpBuffer = {
                .data = tmpBufferData,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = 0,
            };
            err = vImageConvert_ARGB8888toPlanar8(&argbBuffer, &tmpBuffer, &tmpBuffer, &resultBuffer, &tmpBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to convert ARGB to B(Mono): %ld", err);
                goto end_no_alpha_mono;
            }
            result = CreateImageFromBuffer(avif, &resultBuffer);
            resultBufferData = NULL;
        end_no_alpha_mono:
            free(tmpBufferData);
            goto end_no_alpha;
        } else { // no_alpha_color
            err = vImageConvert_ARGB8888toRGB888(&argbBuffer, &resultBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to convert ARGB to RGB: %ld", err);
                goto end_no_alpha_color;
            }
            result = CreateImageFromBuffer(avif, &resultBuffer);
            resultBufferData = NULL;
        end_no_alpha_color:
            goto end_no_alpha;
        }
    end_no_alpha:
        goto end_all;
    }

end_all:
    free(resultBufferData);
    free(argbBufferData);
    free(dummyCbData);
    free(dummyCrData);
    return result;
}

// Convert 10/12bit AVIF image into RGB16U/ARGB16U/Mono16U/MonoA16U
static CGImageRef CreateImage16U(avifImage * avif) {
    CGImageRef result = NULL;
    uint16_t* resultBufferData = NULL;
    uint16_t* argbBufferData = NULL;
    uint16_t* ayuvBufferData = NULL;
    uint16_t* scaledAlphaBufferData = NULL;
    uint16_t* dummyCbData = NULL;
    uint16_t* dummyCrData = NULL;
    uint16_t* dummyAlphaData = NULL;

    vImage_Error err = kvImageNoError;
    
    // image properties
    BOOL const monochrome = avif->yuvPlanes[1] == NULL || avif->yuvPlanes[2] == NULL;
    BOOL const hasAlpha = avif->alphaPlane != NULL;
    size_t const components = (monochrome ? 1 : 3) + (hasAlpha ? 1 : 0);

    // setup conversion info
    avifReformatState state = {0};
    vImage_YpCbCrToARGBMatrix matrix = {0};
    vImage_YpCbCrPixelRange pixelRange = {0};
    SetupConversionInfo(avif, &state, &matrix, &pixelRange);

    vImage_YpCbCrToARGB convInfo = {0};

    resultBufferData = calloc(components * avif->width * avif->height, sizeof(uint16_t));
    ayuvBufferData = calloc(avif->width * avif->height * 4, sizeof(uint16_t));
    if(resultBufferData == NULL || ayuvBufferData == NULL) {
        goto end_all;
    }

    BOOL const useTempBuffer = monochrome || !hasAlpha; // if and only if the image is not ARGB

    if(useTempBuffer) {
        argbBufferData = calloc(avif->width * avif->height * 4, sizeof(uint16_t));
        if(argbBufferData == NULL) {
            goto end_all;
        }
    }

    vImage_Buffer resultBuffer = {
        .data = resultBufferData,
        .width = avif->width,
        .height = avif->height,
        .rowBytes = avif->width * components * sizeof(uint16_t),
    };

    vImage_Buffer argbBuffer = {
        .data = useTempBuffer ? argbBufferData : resultBufferData,
        .width = avif->width,
        .height = avif->height,
        .rowBytes = avif->width * 4 * sizeof(uint16_t),
    };

    vImage_Buffer ayuvBuffer = {
        .data = ayuvBufferData,
        .width = avif->width,
        .height = avif->height,
        .rowBytes = avif->width * 4 * sizeof(uint16_t),
    };

    vImage_Buffer origY = {
        .data = avif->yuvPlanes[AVIF_CHAN_Y],
        .rowBytes = avif->yuvRowBytes[AVIF_CHAN_Y],
        .width = avif->width,
        .height = avif->height,
    };
    
    vImage_Buffer origCb = {
        .data = avif->yuvPlanes[AVIF_CHAN_U],
        .rowBytes = avif->yuvRowBytes[AVIF_CHAN_U],
        .width = (avif->width+state.formatInfo.chromaShiftX) >> state.formatInfo.chromaShiftX,
        .height = (avif->height+state.formatInfo.chromaShiftY) >> state.formatInfo.chromaShiftY,
    };

    if(!origCb.data) { // allocate dummy data to convert monochrome images.
        vImagePixelCount origHeight = origCb.height;
        origCb.rowBytes = origCb.width * sizeof(uint16_t);
        dummyCbData = calloc(origCb.width, sizeof(uint16_t));
        if(!dummyCbData) {
            goto end_all;
        }
        origCb.data = dummyCbData;
        origCb.height = 1;
        // fill zero values.
        err = vImageOverwriteChannelsWithScalar_Planar16U(pixelRange.CbCr_bias, &origCb, kvImageNoFlags);
        if (err != kvImageNoError) {
            NSLog(@"Failed to fill dummy Cr buffer: %ld", err);
            goto end_all;
        }
        origCb.rowBytes = 0;
        origCb.height = origHeight;
    }

    vImage_Buffer origCr = {
        .data = avif->yuvPlanes[AVIF_CHAN_V],
        .rowBytes = avif->yuvRowBytes[AVIF_CHAN_V],
        .width = (avif->width+state.formatInfo.chromaShiftX) >> state.formatInfo.chromaShiftX,
        .height = (avif->height+state.formatInfo.chromaShiftY) >> state.formatInfo.chromaShiftY,
    };

    if(!origCr.data) { // allocate dummy data to convert monochrome images.
        vImagePixelCount origHeight = origCr.height;
        origCr.rowBytes = origCr.width * sizeof(uint16_t);
        dummyCrData = calloc(origCr.width, sizeof(uint16_t));
        if(!dummyCrData) {
            goto end_all;
        }
        origCr.data = dummyCrData;
        origCr.height = 1;
        // fill zero values.
        err = vImageOverwriteChannelsWithScalar_Planar16U(pixelRange.CbCr_bias, &origCr, kvImageNoFlags);
        if (err != kvImageNoError) {
            NSLog(@"Failed to fill dummy Cr buffer: %ld", err);
            goto end_all;
        }
        origCr.rowBytes = 0;
        origCr.height = origHeight;
    }

    vImage_Buffer origAlpha = {0};
    if(hasAlpha) {
        float* floatAlphaBufferData = NULL;
        floatAlphaBufferData = calloc(avif->width * avif->height, sizeof(float));
        scaledAlphaBufferData = calloc(avif->width * avif->height, sizeof(uint16_t));
        if(floatAlphaBufferData == NULL || scaledAlphaBufferData == NULL) {
            err = kvImageMemoryAllocationError;
            goto end_prepare_alpha;
        }
        origAlpha.data = avif->alphaPlane;
        origAlpha.width = avif->width;
        origAlpha.height = avif->height;
        origAlpha.rowBytes = avif->alphaRowBytes;
        
        vImage_Buffer floatAlphaBuffer = {
            .data = floatAlphaBufferData,
            .width = avif->width,
            .height = avif->height,
            .rowBytes = avif->width * sizeof(float),
        };
        vImage_Buffer scaledAlphaBuffer = {
            .data = scaledAlphaBufferData,
            .width = avif->width,
            .height = avif->height,
            .rowBytes = avif->width * sizeof(uint16_t),
        };
        err = vImageConvert_16UToF(&origAlpha, &floatAlphaBuffer, 0.0f, 1.0f, kvImageNoFlags);
        if(err != kvImageNoError) {
            NSLog(@"Failed to convert alpha planes from uint16 to float: %ld", err);
            goto end_prepare_alpha;
        }
        float scale = 1.0f;
        if(avif->depth == 10) {
            scale = (float)((1 << 10) - 1) / 65535.0f;
        } else if(avif->depth == 12) {
            scale = (float)((1 << 12) - 1) / 65535.0f;
        }
        err = vImageConvert_FTo16U(&floatAlphaBuffer, &scaledAlphaBuffer, 0.0f, scale, kvImageNoFlags);
        if(err != kvImageNoError) {
            NSLog(@"Failed to convert alpha planes from uint16 to float: %ld", err);
            goto end_prepare_alpha;
        }
        origAlpha.data = scaledAlphaBufferData;
        origAlpha.rowBytes = avif->width * sizeof(uint16_t);
    end_prepare_alpha:
        free(floatAlphaBufferData);
        if(err != kvImageNoError) {
            goto end_all;
        }
    } else {
        // allocate dummy data to convert monochrome images.
        origAlpha.rowBytes = avif->width * sizeof(uint16_t);
        dummyAlphaData = calloc(avif->width, sizeof(uint16_t));
        if(!dummyAlphaData) {
            goto end_all;
        }
        origAlpha.data = dummyAlphaData;
        origAlpha.width = avif->width;
        origAlpha.height = 1;
        err = vImageOverwriteChannelsWithScalar_Planar16U(0xffff, &origAlpha, kvImageNoFlags);
        if (err != kvImageNoError) {
            NSLog(@"Failed to fill dummy alpha buffer: %ld", err);
            goto end_all;
        }
        origAlpha.rowBytes = 0;
        origAlpha.height = avif->height;
    };
    

    uint8_t const permuteMap[4] = {0, 1, 2, 3};
    switch(avif->yuvFormat) {
        case AVIF_PIXEL_FORMAT_NONE:
            NSLog(@"Invalid pixel format.");
            goto end_all;
        case AVIF_PIXEL_FORMAT_YUV420:
        case AVIF_PIXEL_FORMAT_YUV422:
        case AVIF_PIXEL_FORMAT_YV12:
        {
            uint16_t* scaledCbData = NULL;
            uint16_t* scaledCrData = NULL;
            void* scaleTempBuff = NULL;

            scaledCbData = calloc(avif->width * avif->height * 4, sizeof(uint16_t));
            scaledCrData = calloc(avif->width * avif->height * 4, sizeof(uint16_t));
            if(scaledCbData == NULL || scaledCrData == NULL) {
                err = kvImageMemoryAllocationError;
                goto end_420;
            }
            vImage_Buffer scaledCb = {
                .data = scaledCbData,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->width * 4 * sizeof(uint16_t),
            };
            vImage_Buffer scaledCr = {
                .data = scaledCrData,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->width * 4 * sizeof(uint16_t),
            };
            vImage_Error scaleTempBuffSize = vImageScale_Planar16U(&origCb, &scaledCb, NULL, kvImageGetTempBufferSize);
            if(scaleTempBuffSize < 0) {
                NSLog(@"Failed to get temp buffer size: %ld", scaleTempBuffSize);
                goto end_420;
            }
            scaleTempBuff = malloc(scaleTempBuffSize);
            if(scaleTempBuff == NULL) {
                err = kvImageMemoryAllocationError;
                goto end_420;
            }
            // upscale Cb
            err = vImageScale_Planar16U(&origCb, &scaledCb, scaleTempBuff, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to scale Cb: %ld", err);
                goto end_420;
            }
            // upscale Cr
            err = vImageScale_Planar16U(&origCr, &scaledCr, scaleTempBuff, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to scale Cb: %ld", err);
                goto end_420;
            }
            err = vImageConvert_Planar16UtoARGB16U(&origAlpha, &origY, &scaledCb, &scaledCr, &ayuvBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to composite kvImage444AYpCbCr16: %ld", err);
                goto end_420;
            }
        end_420:
            free(scaledCrData);
            free(scaledCbData);
            free(scaleTempBuff);
            if(err == kvImageNoError) {
                break;
            } else {
                goto end_all;
            }
        }
        case AVIF_PIXEL_FORMAT_YUV444:
        {
            err = vImageConvert_Planar16UtoARGB16U(&origAlpha, &origY, &origCb, &origCr, &ayuvBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to composite kvImage444AYpCbCr16: %ld", err);
                goto end_444;
            }
        end_444:
            if(err == kvImageNoError) {
                break;
            } else {
                goto end_all;
            }
        }
    }
    free(dummyCbData);
    dummyCbData = NULL;
    free(dummyCrData);
    dummyCrData = NULL;
    free(dummyAlphaData);
    dummyAlphaData = NULL;
    free(scaledAlphaBufferData);
    scaledAlphaBufferData = NULL;

    err = vImageConvert_YpCbCrToARGB_GenerateConversion(&matrix,
                                                        &pixelRange,
                                                        &convInfo,
                                                        kvImage444AYpCbCr16,
                                                        kvImageARGB16U,
                                                        kvImageNoFlags);
    if(err != kvImageNoError) {
        NSLog(@"Failed to setup conversion: %ld", err);
        goto end_all;
    }
    err = vImageConvert_444AYpCbCr16ToARGB16U(&ayuvBuffer,
                                              &argbBuffer,
                                              &convInfo,
                                              permuteMap,
                                              kvImageNoFlags);
    if(err != kvImageNoError) {
        NSLog(@"Failed to convert to ARGB16U: %ld", err);
        goto end_all;
    }

    if(hasAlpha) { // alpha
        if(monochrome){ // alpha_mono
            uint16_t* tmpBufferData = NULL;
            uint16_t* alphaBufferData = NULL;
            uint16_t* monoBufferData = NULL;
            uint8_t* alphaBuffer1Data = NULL;
            uint8_t* alphaBuffer2Data = NULL;
            uint8_t* monoBuffer1Data = NULL;
            uint8_t* monoBuffer2Data = NULL;
            
            tmpBufferData = calloc(avif->width, sizeof(uint16_t));
            alphaBufferData = calloc(avif->width * avif->height, sizeof(uint16_t));
            monoBufferData = calloc(avif->width * avif->height, sizeof(uint16_t));
            
            monoBuffer1Data = calloc(avif->width * avif->height, sizeof(uint8_t));
            monoBuffer2Data = calloc(avif->width * avif->height, sizeof(uint8_t));

            alphaBuffer1Data = calloc(avif->width * avif->height, sizeof(uint8_t));
            alphaBuffer2Data = calloc(avif->width * avif->height, sizeof(uint8_t));
            
            if(tmpBufferData == NULL ||
               alphaBufferData == NULL ||
               monoBufferData == NULL ||
               alphaBuffer1Data == NULL ||
               alphaBuffer2Data == NULL ||
               monoBuffer1Data == NULL ||
               monoBuffer2Data == NULL){
                goto end_alpha_mono;
            }

            vImage_Buffer tmpBuffer = {
                .data = tmpBufferData,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = 0,
            };
            vImage_Buffer alphaBuffer = {
                .data = alphaBufferData,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->width * sizeof(uint16_t),
            };
            vImage_Buffer monoBuffer = {
                .data = monoBufferData,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->width * sizeof(uint16_t),
            };
            vImage_Buffer monoBuffer1 = {
                .data = monoBuffer1Data,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->width * sizeof(uint8_t),
            };
            vImage_Buffer monoBuffer2 = {
                .data = monoBuffer2Data,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->width * sizeof(uint8_t),
            };
            vImage_Buffer alphaBuffer1 = {
                .data = alphaBuffer1Data,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->width * sizeof(uint8_t),
            };
            vImage_Buffer alphaBuffer2 = {
                .data = alphaBuffer2Data,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->width * sizeof(uint8_t),
            };

            err = vImageConvert_ARGB16UtoPlanar16U(&argbBuffer, &alphaBuffer, &tmpBuffer, &monoBuffer, &tmpBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to convert ARGB to Mono: %ld", err);
                goto end_alpha_mono;
            }
            err = vImageConvert_ChunkyToPlanar8((const void*[]){monoBuffer.data, monoBuffer.data + 1},
                                               (const vImage_Buffer*[]){&monoBuffer1, &monoBuffer2},
                                               2 /* channelCount */, 2 /* src srcStrideBytes */,
                                               monoBuffer.width, monoBuffer.height,
                                               monoBuffer.rowBytes, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to split Mono16: %ld", err);
                goto end_alpha_mono;
            }

            err = vImageConvert_ChunkyToPlanar8((const void*[]){alphaBuffer.data, alphaBuffer.data + 1},
                                               (const vImage_Buffer*[]){&alphaBuffer1, &alphaBuffer2},
                                               2 /* channelCount */, 2 /* src srcStrideBytes */,
                                               alphaBuffer.width, alphaBuffer.height,
                                               alphaBuffer.rowBytes, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to split Mono16: %ld", err);
                goto end_alpha_mono;
            }

            err = vImageConvert_Planar8toARGB8888(&alphaBuffer1, &alphaBuffer2, &monoBuffer1, &monoBuffer2, &resultBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                free(resultBufferData);
                NSLog(@"Failed to convert Planar Alpha + Mono to MonoA: %ld", err);
                goto end_alpha_mono;
            }
            result = CreateImageFromBuffer(avif, &resultBuffer);
            resultBufferData = NULL;
        end_alpha_mono:
            free(tmpBufferData);
            free(alphaBufferData);
            free(monoBufferData);
            free(alphaBuffer1Data);
            free(alphaBuffer2Data);
            free(monoBuffer1Data);
            free(monoBuffer2Data);
            goto end_alpha;
        }else{ // alpha_color
            result = CreateImageFromBuffer(avif, &resultBuffer);
            resultBufferData = NULL;
        end_alpha_color:
            goto end_alpha;
        }
    end_alpha:
        goto end_all;
    } else { // no_alpha
        if(monochrome) { // no_alpha_mono
            uint16_t* tmpBufferData = NULL;
            tmpBufferData = calloc(avif->width, sizeof(uint16_t));
            if(tmpBufferData == NULL) {
                goto end_no_alpha_mono;
            }
            vImage_Buffer tmpBuffer = {
                .data = tmpBufferData,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = 0,
            };
            err = vImageConvert_ARGB16UtoPlanar16U(&argbBuffer, &tmpBuffer, &tmpBuffer, &resultBuffer, &tmpBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to convert ARGB to Mono: %ld", err);
                goto end_no_alpha_mono;
            }
            result = CreateImageFromBuffer(avif, &resultBuffer);
            resultBufferData = NULL;
        end_no_alpha_mono:
            free(tmpBufferData);
            goto end_no_alpha;
        } else { // no_alpha_color
            err = vImageConvert_ARGB16UtoRGB16U(&argbBuffer, &resultBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to convert ARGB to RGB: %ld", err);
                goto end_no_alpha_color;
            }
            result = CreateImageFromBuffer(avif, &resultBuffer);
            resultBufferData = NULL;
        end_no_alpha_color:
            goto end_no_alpha;
        }
    end_no_alpha:
        goto end_all;
    }
end_all:
    free(resultBufferData);
    free(argbBufferData);
    free(ayuvBufferData);
    free(scaledAlphaBufferData);
    free(dummyCbData);
    free(dummyCrData);
    free(dummyAlphaData);
    return result;
}

static void FillRGBABufferWithAVIFImage(vImage_Buffer *red, vImage_Buffer *green, vImage_Buffer *blue, vImage_Buffer *alpha, avifImage *img) {
    red->width = img->width;
    red->height = img->height;
    red->data = img->rgbPlanes[AVIF_CHAN_R];
    red->rowBytes = img->rgbRowBytes[AVIF_CHAN_R];
    
    green->width = img->width;
    green->height = img->height;
    green->data = img->rgbPlanes[AVIF_CHAN_G];
    green->rowBytes = img->rgbRowBytes[AVIF_CHAN_G];
    
    blue->width = img->width;
    blue->height = img->height;
    blue->data = img->rgbPlanes[AVIF_CHAN_B];
    blue->rowBytes = img->rgbRowBytes[AVIF_CHAN_B];
    
    if (img->alphaPlane != NULL) {
        alpha->width = img->width;
        alpha->height = img->height;
        alpha->data = img->alphaPlane;
        alpha->rowBytes = img->alphaRowBytes;
    }
}

@implementation SDImageAVIFCoder

+ (instancetype)sharedCoder {
    static SDImageAVIFCoder *coder;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coder = [[SDImageAVIFCoder alloc] init];
    });
    return coder;
}

- (BOOL)canDecodeFromData:(NSData *)data {
    return [[self class] isAVIFFormatForData:data];
}

- (UIImage *)decodedImageWithData:(NSData *)data options:(SDImageCoderOptions *)options {
    if (!data) {
        return nil;
    }
    CGFloat scale = 1;
    if ([options valueForKey:SDImageCoderDecodeScaleFactor]) {
        scale = [[options valueForKey:SDImageCoderDecodeScaleFactor] doubleValue];
        if (scale < 1) {
            scale = 1;
        }
    }
    
    // Currently only support primary image :)
    CGImageRef imageRef = [self sd_createAVIFImageWithData:data];
    if (!imageRef) {
        return nil;
    }
    
#if SD_MAC
    UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:kCGImagePropertyOrientationUp];
#else
    UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:UIImageOrientationUp];
#endif
    CGImageRelease(imageRef);
    
    return image;
}

- (nullable CGImageRef)sd_createAVIFImageWithData:(nonnull NSData *)data CF_RETURNS_RETAINED {
    // Decode it
    avifROData rawData = {
        .data = (uint8_t *)data.bytes,
        .size = data.length
    };
    avifDecoder * decoder = avifDecoderCreate();
    avifResult decodeResult = avifDecoderParse(decoder, &rawData);
    if (decodeResult != AVIF_RESULT_OK) {
        NSLog(@"Failed to decode image: %s", avifResultToString(decodeResult));
        avifDecoderDestroy(decoder);
        return nil;
    }
    avifResult nextImageResult = avifDecoderNextImage(decoder);
    if (nextImageResult != AVIF_RESULT_OK || nextImageResult == AVIF_RESULT_NO_IMAGES_REMAINING) {
        NSLog(@"Failed to decode image: %s", avifResultToString(nextImageResult));
        avifDecoderDestroy(decoder);
        return nil;
    }
    avifImage * avif = decoder->image;

    CGImageRef image = NULL;
    // convert planar to ARGB/RGB
    if(avifImageUsesU16(avif)) { // 10bit or 12bit
        image = CreateImage16U(avif);
    } else { //8bit
        image = CreateImage8(avif);
    }
    avifDecoderDestroy(decoder);
    return image;
}

// The AVIF encoding seems slow at the current time, but at least works
- (BOOL)canEncodeToFormat:(SDImageFormat)format {
    return format == SDImageFormatAVIF;
}

- (nullable NSData *)encodedDataWithImage:(nullable UIImage *)image format:(SDImageFormat)format options:(nullable SDImageCoderOptions *)options {
    CGImageRef imageRef = image.CGImage;
    if (!imageRef) {
        return nil;
    }
    
    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    size_t bitsPerPixel = CGImageGetBitsPerPixel(imageRef);
    size_t bitsPerComponent = CGImageGetBitsPerComponent(imageRef);
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);
    CGImageAlphaInfo alphaInfo = bitmapInfo & kCGBitmapAlphaInfoMask;
    BOOL hasAlpha = !(alphaInfo == kCGImageAlphaNone ||
                      alphaInfo == kCGImageAlphaNoneSkipFirst ||
                      alphaInfo == kCGImageAlphaNoneSkipLast);
    
    vImageConverterRef convertor = NULL;
    vImage_Error v_error = kvImageNoError;
    
    vImage_CGImageFormat srcFormat = {
        .bitsPerComponent = (uint32_t)bitsPerComponent,
        .bitsPerPixel = (uint32_t)bitsPerPixel,
        .colorSpace = CGImageGetColorSpace(imageRef),
        .bitmapInfo = bitmapInfo
    };
    vImage_CGImageFormat destFormat = {
        .bitsPerComponent = 8,
        .bitsPerPixel = hasAlpha ? 32 : 24,
        .colorSpace = [SDImageCoderHelper colorSpaceGetDeviceRGB],
        .bitmapInfo = hasAlpha ? kCGImageAlphaFirst | kCGBitmapByteOrderDefault : kCGImageAlphaNone | kCGBitmapByteOrderDefault // RGB888/ARGB8888 (Non-premultiplied to works for libavif)
    };
    
    convertor = vImageConverter_CreateWithCGImageFormat(&srcFormat, &destFormat, NULL, kvImageNoFlags, &v_error);
    if (v_error != kvImageNoError) {
        return nil;
    }
    
    vImage_Buffer src;
    v_error = vImageBuffer_InitWithCGImage(&src, &srcFormat, NULL, imageRef, kvImageNoFlags);
    if (v_error != kvImageNoError) {
        return nil;
    }
    vImage_Buffer dest;
    vImageBuffer_Init(&dest, height, width, hasAlpha ? 32 : 24, kvImageNoFlags);
    if (!dest.data) {
        free(src.data);
        return nil;
    }
    
    // Convert input color mode to RGB888/ARGB8888
    v_error = vImageConvert_AnyToAny(convertor, &src, &dest, NULL, kvImageNoFlags);
    free(src.data);
    vImageConverter_Release(convertor);
    if (v_error != kvImageNoError) {
        free(dest.data);
        return nil;
    }
    
    avifPixelFormat avifFormat = AVIF_PIXEL_FORMAT_YUV444;
    enum avifPlanesFlags planesFlags = hasAlpha ? AVIF_PLANES_RGB | AVIF_PLANES_A : AVIF_PLANES_RGB;
    
    avifImage *avif = avifImageCreate((int)width, (int)height, 8, avifFormat);
    if (!avif) {
        free(dest.data);
        return nil;
    }
    avifImageAllocatePlanes(avif, planesFlags);
    
    NSData *iccProfile = (__bridge_transfer NSData *)CGColorSpaceCopyICCProfile([SDImageCoderHelper colorSpaceGetDeviceRGB]);
    
    avifImageSetProfileICC(avif, (uint8_t *)iccProfile.bytes, iccProfile.length);
    
    vImage_Buffer red, green, blue, alpha;
    FillRGBABufferWithAVIFImage(&red, &green, &blue, &alpha, avif);
    
    if (hasAlpha) {
        v_error = vImageConvert_ARGB8888toPlanar8(&dest, &alpha, &red, &green, &blue, kvImageNoFlags);
    } else {
        v_error = vImageConvert_RGB888toPlanar8(&dest, &red, &green, &blue, kvImageNoFlags);
    }
    free(dest.data);
    if (v_error != kvImageNoError) {
        return nil;
    }
    
    double compressionQuality = 1;
    if (options[SDImageCoderEncodeCompressionQuality]) {
        compressionQuality = [options[SDImageCoderEncodeCompressionQuality] doubleValue];
    }
    int rescaledQuality = AVIF_QUANTIZER_WORST_QUALITY - (int)((compressionQuality) * AVIF_QUANTIZER_WORST_QUALITY);
    
    avifRWData raw = AVIF_DATA_EMPTY;
    avifEncoder *encoder = avifEncoderCreate();
    encoder->minQuantizer = rescaledQuality;
    encoder->maxQuantizer = rescaledQuality;
    encoder->maxThreads = 2;
    avifResult result = avifEncoderWrite(encoder, avif, &raw);
    
    if (result != AVIF_RESULT_OK) {
        avifEncoderDestroy(encoder);
        return nil;
    }
    
    NSData *imageData = [NSData dataWithBytes:raw.data length:raw.size];
    free(raw.data);
    avifEncoderDestroy(encoder);
    
    return imageData;
}


#pragma mark - Helper
+ (BOOL)isAVIFFormatForData:(NSData *)data
{
    if (!data) {
        return NO;
    }
    if (data.length >= 12) {
        //....ftypavif ....ftypavis
        NSString *testString = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(4, 8)] encoding:NSASCIIStringEncoding];
        if ([testString isEqualToString:@"ftypavif"]
            || [testString isEqualToString:@"ftypavis"]) {
            return YES;
        }
    }
    
    return NO;
}

@end
