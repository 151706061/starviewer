// tot el que tingui prefix d és del dispositiu

#include "qcudarenderwindow.h"

#include "cudaviewpointintensityinformationchannel.h"

#include <iostream>

#include <cuda.h>
#include <cuda_gl_interop.h>
#include <cutil.h>
#include <cutil_math.h>

#include <vtkImageData.h>

#include "transferfunction.h"
#include "matrix4.h"


//////////////////////////////////////////////////////////////////////////////////// Ray cast ////////////////////////////////////////////////////////////////////////////////////



static const uint ParallelismFactor = 256;  // quantes entrades hi ha a l'histograma enter per cada valor d'intensitat; ajuda a augmentar el paral·lelisme reduint les col·lisions a l'hora d'escriure
static const uint PARTITIONS = 1;  // en quants trossos es parteix la imatge en cada dimensió (per reduir col·lisions)
static const int VOLUME_MULTIPLIER = 10000; // multiplicador del volum a l'hora de convertir-lo en enter


// volum
static cudaArray *gdVolumeArray;
texture<ushort, 3> gVolumeTexture;  // el 3r paràmetre pot ser cudaReadModeElementType (valor directe) (predeterminat) o cudaReadModeNormalizedFloat (valor escalat entre 0 i 1)

// funció de transferència
static cudaArray *gdTransferFunctionArray;
texture<float4, 1> gTransferFunctionTexture;    // podríem passar amb un sol float perquè només ens interessa l'opacitat: seria gaire més eficient?

// histograma
static int *gdiHistogram;
static float *gdfHistogram;

// p(I|v) * totalViewedVolume
texture<float, 1> gViewedVolumesTexture;    // textura de l'histograma de reals

// mida del volum
static uint gIntensityRange;
static cudaExtent gVolumeDataDims;
static float3 gVolumeDims;
static float gMinimumSpacing;

// per mostrar la imatge
static bool gDisplay;
static QCudaRenderWindow *gCudaRenderWindow;
static uint gRenderSize;


struct float3x4
{
    float4 f[3];
};


struct Ray
{
    float3 origin;      // origin
    float3 direction;   // direction
};


// intersect ray with a box
// http://www.siggraph.org/education/materials/HyperGraph/raytrace/rtinter3.htm

__device__ static bool intersectBox(Ray ray, float3 boxmin, float3 boxmax, float *tnear, float *tfar)
{
    // compute intersection of ray with all six bbox planes
    float3 invRay = make_float3(1.0f) / ray.direction;
    float3 tbot = invRay * (boxmin - ray.origin);
    float3 ttop = invRay * (boxmax - ray.origin);

    // re-order intersections to find smallest and largest on each axis
    float3 tmin = fminf(ttop, tbot);
    float3 tmax = fmaxf(ttop, tbot);

    // find the largest tmin and the smallest tmax
    float largest_tmin = fmaxf(fmaxf(tmin.x, tmin.y), fmaxf(tmin.x, tmin.z));
    float smallest_tmax = fminf(fminf(tmax.x, tmax.y), fminf(tmax.x, tmax.z));

    *tnear = largest_tmin;
    *tfar = smallest_tmax;

    return smallest_tmax > largest_tmin;
}


// transform vector by matrix (no translation)
__device__ static float3 mul(const float3x4 &M, const float3 &v)
{
    float3 r;
    r.x = dot(v, make_float3(M.f[0]));
    r.y = dot(v, make_float3(M.f[1]));
    r.z = dot(v, make_float3(M.f[2]));
    return r;
}


// transform vector by matrix with translation
__device__ static float4 mul(const float3x4 &M, const float4 &v)
{
    float4 r;
    r.x = dot(v, M.f[0]);
    r.y = dot(v, M.f[1]);
    r.z = dot(v, M.f[2]);
    r.w = 1.0f;
    return r;
}


__device__ static uint rgbaFloatToInt(float4 rgba)
{
    rgba.x = __saturatef(rgba.x);   // clamp to [0.0, 1.0]
    rgba.y = __saturatef(rgba.y);
    rgba.z = __saturatef(rgba.z);
    rgba.w = __saturatef(rgba.w);
    return (uint(rgba.w*255)<<24) | (uint(rgba.z*255)<<16) | (uint(rgba.y*255)<<8) | uint(rgba.x*255);
}


__global__ void rayCastKernel(uint *image, uint imageWidth, uint imageHeight, int *histogram, float3 volumeDims, float rayStep, float3x4 invViewMatrix, uint parallelismFactor, uint partitions, int volumeMultiplier)
{
    const int MAX_STEPS = 1024;
    const float OPAQUE_ALPHA = 0.99f;

    float3 boxMin = make_float3(-volumeDims.x / 2.0f, -volumeDims.y / 2.0f, -volumeDims.z / 2.0f);
    float3 boxMax = make_float3(volumeDims.x / 2.0f, volumeDims.y / 2.0f, volumeDims.z / 2.0f);

    for (int pi = 0; pi < partitions; pi++)
    {
        for (int pj = 0; pj < partitions; pj++)
        {
            // píxel de la imatge on escriurem
            uint x = (__umul24(blockIdx.x, blockDim.x) + threadIdx.x) * partitions + pi;
            uint y = (__umul24(blockIdx.y, blockDim.y) + threadIdx.y) * partitions + pj;

            if (x >= imageWidth || y >= imageHeight) continue;

            // coordenades del píxel normalitzades a [-1,1]
            float u = (x / (float) (imageWidth-1)) * 2.0f - 1.0f;
            float v = (y / (float) (imageHeight-1)) * 2.0f - 1.0f;

            // calculate eye ray in world space
            Ray eyeRay;
            //eyeRay.o = make_float3(mul(c_invViewMatrix, make_float4(0.0f, 0.0f, 0.0f, 1.0f)));
            //eyeRay.d = normalize(make_float3(u, v, -2.0f));
            //eyeRay.d = mul(c_invViewMatrix, eyeRay.d);
            eyeRay.origin = make_float3(mul(invViewMatrix, make_float4(0.0f, 0.0f, 0.0f, 1.0f)));
            eyeRay.direction = normalize(make_float3(u, v, -3.0f)); // amb el 3 crec que s'assembla més a com es veu amb vtk
            eyeRay.direction = mul(invViewMatrix, eyeRay.direction);

            // find intersection with box
            float tnear, tfar;
            bool hit = intersectBox(eyeRay, boxMin, boxMax, &tnear, &tfar);

            if (!hit) continue; // no hi ha intersecció

            if (tnear < 0.0f) tnear = 0.0f; // clamp to near plane

            // march along ray from front to back, accumulating color
            float4 sum = make_float4(0.0f);
            float remainingOpacity = 1.0f;
            float t = tnear;
            float maxSample = 0.0f;

            for (int i = 0; i < MAX_STEPS; i++)
            {
                float3 pos = eyeRay.origin + eyeRay.direction * t;
                //pos = pos * 0.5f + 0.5f;    // map position to [0, 1] coordinates
                pos.x = pos.x / volumeDims.x + 0.5f;
                pos.y = pos.y / volumeDims.y + 0.5f;
                pos.z = pos.z / volumeDims.z + 0.5f;
                // ara pos està a [0,1)

                // read from 3D texture
                float sample = tex3D(gVolumeTexture, pos.x, pos.y, pos.z);
                if (sample > maxSample) maxSample = sample;

                // lookup in transfer function texture
                float4 col = tex1D(gTransferFunctionTexture, sample);
                //if (col.w > maxSample) maxSample = col.w;
                //maxSample += 1.0f / MAX_STEPS;

                float volume = col.w * remainingOpacity;

                if (volume > 0.0f)
                {
                    int offset = ((int) sample) * parallelismFactor + ((threadIdx.x + threadIdx.y * blockDim.x) % parallelismFactor);

                    int iVolume = (int) (volume * volumeMultiplier);
                    atomicAdd(histogram + offset, iVolume);

                    // accumulate result
                    //sum = lerp(sum, col, col.w*density);
                    sum.x += col.x * col.w * remainingOpacity;
                    sum.y += col.y * col.w * remainingOpacity;
                    sum.z += col.z * col.w * remainingOpacity;
                    remainingOpacity *= 1.0f - col.w;
                    sum.w = 1.0f - remainingOpacity;

                    if (sum.w >= OPAQUE_ALPHA) break;
                }

                t += rayStep;

                if (t > tfar) break;
            }

            if (image)
            {
                // write output color
                uint i = __umul24(y, imageWidth) + x;
                image[i] = rgbaFloatToInt(sum);
            }
        }   // pj
    }   // pi
}


__global__ void histogramToFloatKernel(int *iHistogram, float *fHistogram, uint range, uint parallelismFactor, int volumeMultiplier)
{
    uint i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= range) return;

    double divisor = volumeMultiplier;
    double total = 0.0;

    for (uint j = 0; j < parallelismFactor; j++) total += iHistogram[i * parallelismFactor + j] / divisor;

    fHistogram[i] = total;
}


void cviicSetupRayCast(vtkImageData *image, const TransferFunction &transferFunction, int renderSize, int displaySize, QColor backgroundColor, bool display)
{
    ushort *data = reinterpret_cast<unsigned short*>(image->GetScalarPointer());
    gIntensityRange = static_cast<uint>(image->GetScalarRange()[1]) + 1;
    int *dimensions = image->GetDimensions();
    gVolumeDataDims = make_cudaExtent(dimensions[0], dimensions[1], dimensions[2]);
    double *spacing = image->GetSpacing();
    gVolumeDims = make_float3(dimensions[0] * spacing[0], dimensions[1] * spacing[1], dimensions[2] * spacing[2]);
    gMinimumSpacing = qMin(qMin(spacing[0], spacing[1]), spacing[2]);
    double *scalarRange = image->GetScalarRange();
    int rangeMax = static_cast<int>(scalarRange[1]);

    // create 3D array
    cudaChannelFormatDesc channelDescVolumeArray = cudaCreateChannelDesc<ushort>();
    CUDA_SAFE_CALL( cudaMalloc3DArray(&gdVolumeArray, &channelDescVolumeArray, gVolumeDataDims) );

    // copy data to 3D array
    cudaMemcpy3DParms copyParams = {0};
    copyParams.srcPtr = make_cudaPitchedPtr(reinterpret_cast<void*>(data), dimensions[0] * sizeof(ushort), dimensions[0], dimensions[1]);   // data, pitch, width, height
    copyParams.dstArray = gdVolumeArray;
    copyParams.extent = gVolumeDataDims;
    copyParams.kind = cudaMemcpyHostToDevice;
    CUDA_SAFE_CALL( cudaMemcpy3D(&copyParams) );

    // 3D texture parameters
    gVolumeTexture.normalized = true;                      // false (predeterminat) -> [0,N) | true -> [0,1)
    //gVolumeTexture.filterMode = cudaFilterModePoint;        // cudaFilterModePoint (predeterminat) o cudaFilterModeLinear
    //gVolumeTexture.addressMode[0] = cudaAddressModeClamp;   // cudaAddressModeClamp (retallar) (predeterminat) o cudaAddressModeWrap (fer la volta)
    //gVolumeTexture.addressMode[1] = cudaAddressModeClamp;
    //gVolumeTexture.addressMode[2] = cudaAddressModeClamp;

    // bind array to 3D texture
    CUDA_SAFE_CALL( cudaBindTextureToArray(gVolumeTexture, gdVolumeArray, channelDescVolumeArray) );

    // create 1D array
    cudaChannelFormatDesc channelDescTransferFunctionArray = cudaCreateChannelDesc<float4>();
    CUDA_SAFE_CALL( cudaMallocArray(&gdTransferFunctionArray, &channelDescTransferFunctionArray, rangeMax + 1, 1) );

    // fill 1D array
    float4 *transferFunctionTempArray = new float4[rangeMax + 1];
    for (int i = 0; i <= rangeMax; i++)
    {
        QColor color = transferFunction.getColor(i);
        double opacity = transferFunction.getOpacity(i);
        transferFunctionTempArray[i] = make_float4(color.redF(), color.greenF(), color.blueF(), opacity);
        //transferFunctionTempArray[4*i+0] = color.redF();
        //transferFunctionTempArray[4*i+1] = color.greenF();
        //transferFunctionTempArray[4*i+2] = color.blueF();
        //transferFunctionTempArray[4*i+3] = color.alphaF();
    }
    CUDA_SAFE_CALL( cudaMemcpyToArray(gdTransferFunctionArray, 0, 0, reinterpret_cast<void*>(transferFunctionTempArray), (rangeMax + 1) * sizeof(float4), cudaMemcpyHostToDevice) );
    delete[] transferFunctionTempArray;

    // 1D texture parameters
    //gTransferFunctionTexture.normalized = false;                    // false (predeterminat) -> [0,N) | true -> [0,1)
    //gTransferFunctionTexture.filterMode = cudaFilterModePoint;      // cudaFilterModePoint (predeterminat) o cudaFilterModeLinear
    //gTransferFunctionTexture.addressMode[0] = cudaAddressModeClamp; // cudaAddressModeClamp (retallar) (predeterminat) o cudaAddressModeWrap (fer la volta)

    // bind array to 1D texture
    CUDA_SAFE_CALL( cudaBindTextureToArray(gTransferFunctionTexture, gdTransferFunctionArray, channelDescTransferFunctionArray) );

    // create histogram
    CUDA_SAFE_CALL(cudaMalloc(reinterpret_cast<void**>(&gdiHistogram), gIntensityRange * sizeof(int) * ParallelismFactor));
    CUDA_SAFE_CALL( cudaMalloc(reinterpret_cast<void**>(&gdfHistogram), gIntensityRange * sizeof(float)) );

    // histogram texture (p(I|v) * totalViewedVolume)
    CUDA_SAFE_CALL( cudaBindTexture(0, gViewedVolumesTexture, reinterpret_cast<void*>(gdfHistogram), gViewedVolumesTexture.channelDesc, gIntensityRange * sizeof(float)) );

    // create render window
    gDisplay = display;
    if (display)
    {
        gCudaRenderWindow = new QCudaRenderWindow(backgroundColor, renderSize);
        gCudaRenderWindow->resize(displaySize, displaySize);
        gCudaRenderWindow->show();
    }
    else gCudaRenderWindow = 0;
    gRenderSize = renderSize;

    if (display)
    {
        CUDA_SAFE_CALL( cudaGLRegisterBufferObject(gCudaRenderWindow->pixelBufferObject()) );
    }
}


QVector<float> cviicRayCastAndGetHistogram(Vector3 viewpoint, Matrix4 viewMatrix)
{
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start, 0);

    CUDA_SAFE_CALL(cudaMemset(reinterpret_cast<void*>(gdiHistogram), 0, gIntensityRange * sizeof(int) * ParallelismFactor));    // buidar histograma

    // map PBO to get CUDA device pointer
    uint *pbo = 0;
    if (gDisplay)
    {
        CUDA_SAFE_CALL( cudaGLMapBufferObject(reinterpret_cast<void**>(&pbo), gCudaRenderWindow->pixelBufferObject()) );
        CUDA_SAFE_CALL( cudaMemset(pbo, 0, gRenderSize * gRenderSize * sizeof(uint)) );   // això és per esborrar-lo
    }

    // call CUDA kernel, writing results to FBO
    dim3 blockSize(16, 16);
    dim3 gridSize(gRenderSize / blockSize.x / PARTITIONS, gRenderSize / blockSize.y / PARTITIONS);
    float3x4 invViewMatrix;
    invViewMatrix.f[0] = make_float4(viewMatrix[0][0], viewMatrix[0][1], viewMatrix[0][2], viewpoint.x);
    invViewMatrix.f[1] = make_float4(viewMatrix[1][0], viewMatrix[1][1], viewMatrix[1][2], viewpoint.y);
    invViewMatrix.f[2] = make_float4(viewMatrix[2][0], viewMatrix[2][1], viewMatrix[2][2], viewpoint.z);

    rayCastKernel<<<gridSize, blockSize>>>(pbo, gRenderSize, gRenderSize, gdiHistogram, gVolumeDims, gMinimumSpacing, invViewMatrix, ParallelismFactor, PARTITIONS, VOLUME_MULTIPLIER);
    //CUT_CHECK_ERROR( "kernel failed" );
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess != err) std::cout << "ray cast kernel failed: " << cudaGetErrorString(err) << std::endl;
    err = cudaThreadSynchronize();
    if (cudaSuccess != err) std::cout << "sync after ray cast kernel failed: " << cudaGetErrorString(err) << std::endl;


    if (gDisplay)
    {
        CUDA_SAFE_CALL( cudaGLUnmapBufferObject(gCudaRenderWindow->pixelBufferObject()) );
    }


    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    float elapsedTime1;
    cudaEventElapsedTime(&elapsedTime1, start, stop);

    if (gDisplay) gCudaRenderWindow->updateGL();



    cudaEventRecord(start, 0);

    dim3 blockSize2(512);
    uint zo = gIntensityRange % blockSize2.x == 0 ? 0 : 1;
    dim3 gridSize2(gIntensityRange / blockSize2.x + zo);

    histogramToFloatKernel<<<gridSize2, blockSize2>>>(gdiHistogram, gdfHistogram, gIntensityRange, ParallelismFactor, VOLUME_MULTIPLIER);
    //CUT_CHECK_ERROR( "kernel failed" );
    /*cudaError_t*/ err = cudaGetLastError();
    if (cudaSuccess != err) std::cout << "int->float kernel failed: " << cudaGetErrorString(err) << std::endl;
    err = cudaThreadSynchronize();
    if (cudaSuccess != err) std::cout << "sync after int->float kernel failed: " << cudaGetErrorString(err) << std::endl;

    QVector<float> histogram(gIntensityRange);
    CUDA_SAFE_CALL( cudaMemcpy(reinterpret_cast<void*>(histogram.data()), reinterpret_cast<void*>(gdfHistogram), gIntensityRange * sizeof(float), cudaMemcpyDeviceToHost) );

    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    float elapsedTime2 = 0.0f;
    cudaEventElapsedTime(&elapsedTime2, start, stop);

    std::cout << "ray cast: " << elapsedTime1 << " ms + " << elapsedTime2 << " ms" << std::endl;

    cudaEventDestroy(start);
    cudaEventDestroy(stop);

    return histogram;
}

void cviicCleanupRayCast()
{
    CUDA_SAFE_CALL( cudaUnbindTexture(gVolumeTexture) );
    CUDA_SAFE_CALL( cudaFreeArray(gdVolumeArray) );
    CUDA_SAFE_CALL( cudaUnbindTexture(gTransferFunctionTexture) );
    CUDA_SAFE_CALL( cudaFreeArray(gdTransferFunctionArray) );
    CUDA_SAFE_CALL( cudaUnbindTexture(gViewedVolumesTexture) );
    CUDA_SAFE_CALL( cudaFree(gdiHistogram) );
    CUDA_SAFE_CALL( cudaFree(gdfHistogram) );
    if (gDisplay)
    {
        CUDA_SAFE_CALL( cudaGLUnregisterBufferObject(gCudaRenderWindow->pixelBufferObject()) );
        delete gCudaRenderWindow;
    }
}



//////////////////////////////////////////////////////////////////////////////////// p(I) ////////////////////////////////////////////////////////////////////////////////////



static float *gdIntensityProbabilities;
texture<float, 1> gIntensityProbabilitiesTexture;


__global__ void intensityProbabilitiesKernel(float pv, float totalViewedVolume, uint range, float *intensityProbabilities)
{
    uint i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= range) return;

    float piv = tex1Dfetch(gViewedVolumesTexture, i) / totalViewedVolume;

    intensityProbabilities[i] += pv * piv;
}


void cviicSetupIntensityProbabilities()
{
    CUDA_SAFE_CALL( cudaMalloc(reinterpret_cast<void**>(&gdIntensityProbabilities), gIntensityRange * sizeof(float)) );
    CUDA_SAFE_CALL( cudaMemset(reinterpret_cast<void*>(gdIntensityProbabilities), 0, gIntensityRange * sizeof(float)) );
    CUDA_SAFE_CALL( cudaBindTexture(0, gIntensityProbabilitiesTexture, reinterpret_cast<void*>(gdIntensityProbabilities), gIntensityProbabilitiesTexture.channelDesc, gIntensityRange * sizeof(float)) );
}


void cviicAccumulateIntensityProbabilities( float viewProbability, float totalViewedVolume )
{
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start, 0);

    // Kernel

    dim3 blockSize(512);
    uint zo = gIntensityRange % blockSize.x == 0 ? 0 : 1;
    dim3 gridSize(gIntensityRange / blockSize.x + zo);

    intensityProbabilitiesKernel<<<gridSize, blockSize>>>(viewProbability, totalViewedVolume, gIntensityRange, gdIntensityProbabilities);
    CUT_CHECK_ERROR( "intensity probabilities kernel failed" );

    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    float elapsedTime = 0.0f;
    cudaEventElapsedTime(&elapsedTime, start, stop);

    std::cout << "p(I): " << elapsedTime << " ms" << std::endl;

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
}


QVector<float> cviicGetIntensityProbabilities()
{
    QVector<float> intensityProbabilities( gIntensityRange );
    CUDA_SAFE_CALL( cudaMemcpy(reinterpret_cast<void*>(intensityProbabilities.data()), reinterpret_cast<void*>(gdIntensityProbabilities), gIntensityRange * sizeof(float), cudaMemcpyDeviceToHost) );
    return intensityProbabilities;
}


void cviicCleanupIntensityProbabilities()
{
    CUDA_SAFE_CALL( cudaUnbindTexture(gIntensityProbabilitiesTexture) );
    CUDA_SAFE_CALL( cudaFree(gdIntensityProbabilities) );
}



//////////////////////////////////////////////////////////////////////////////////// IMI ////////////////////////////////////////////////////////////////////////////////////



static float *gdImi = 0;
//static float3 *gdColorVomi = 0;


__global__ void imiKernel(float pv, float totalViewedVolume, uint range, float *imi)
{
    uint i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= range) return;

    float pi = tex1Dfetch(gIntensityProbabilitiesTexture, i);
    float piv = tex1Dfetch(gViewedVolumesTexture, i) / totalViewedVolume;
    float pvi = pv * piv / pi;

    if ( pvi > 0.0f ) imi[i] += pvi * log2f( pvi / pv );
}


/*
__global__ void colorVomiKernel(float pv, float3 color, float totalViewedVolume, cudaExtent volumeDataDims, float3 *colorVomi)
{
    uint blocksX = (volumeDataDims.width + blockDim.x - 1) / blockDim.x;
    uint blockX = blockIdx.x % blocksX;
    uint blockY = blockIdx.x / blocksX;
    uint blockZ = blockIdx.y;

    uint x = blockX * blockDim.x + threadIdx.x;
    if (x >= volumeDataDims.width) return;
    uint y = blockY * blockDim.y + threadIdx.y;
    if (y >= volumeDataDims.height) return;
    uint z = blockZ * blockDim.z + threadIdx.z;
    if (z >= volumeDataDims.depth) return;

    uint i = x + y * volumeDataDims.width + z * volumeDataDims.width * volumeDataDims.height;

    float pz = tex1Dfetch(gVoxelProbabilitiesTexture, i);
    float pzv = tex1Dfetch(gViewedVolumesTexture, i) / totalViewedVolume;
    float pvz = pv * pzv / pz;

    if ( pvz > 0.0f ) colorVomi[i] += pvz * log2f( pvz / pv ) * color;
}
*/


void cviicSetupImi(/*bool vomi, bool colorVomi*/)
{
    //if (vomi)
    {
        CUDA_SAFE_CALL( cudaMalloc(reinterpret_cast<void**>(&gdImi), gIntensityRange * sizeof(float)) );
        CUDA_SAFE_CALL( cudaMemset(reinterpret_cast<void*>(gdImi), 0, gIntensityRange * sizeof(float)) );
    }

    /*
    if (colorVomi)
    {
        CUDA_SAFE_CALL( cudaMalloc(reinterpret_cast<void**>(&gdColorVomi), gVolumeDataSize * sizeof(float3)) );
        CUDA_SAFE_CALL( cudaMemset(reinterpret_cast<void*>(gdColorVomi), 0, gVolumeDataSize * sizeof(float3)) );
    }
    */
}


void cviicAccumulateImi(float viewProbability, float totalViewedVolume)
{
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start, 0);

    // Kernel

    dim3 blockSize(512);
    uint zo = gIntensityRange % blockSize.x == 0 ? 0 : 1;
    dim3 gridSize(gIntensityRange / blockSize.x + zo);

    imiKernel<<<gridSize, blockSize>>>(viewProbability, totalViewedVolume, gIntensityRange, gdImi);
    CUT_CHECK_ERROR( "imi kernel failed" );

    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    float elapsedTime = 0.0f;
    cudaEventElapsedTime(&elapsedTime, start, stop);

    std::cout << "IMI: " << elapsedTime << " ms" << std::endl;

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
}


/*
void cvicAccumulateColorVomi(float viewProbability, const Vector3Float &viewColor, float totalViewedVolume)
{
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start, 0);

    // Kernel

    dim3 blockSize(8, 8, 8);
    uint blocksX = (gVolumeDataDims.width + blockSize.x - 1) / blockSize.x;
    uint blocksY = (gVolumeDataDims.height + blockSize.y - 1) / blockSize.y;
    uint blocksZ = (gVolumeDataDims.depth + blockSize.z - 1) / blockSize.z;
    dim3 gridSize(blocksX * blocksY, blocksZ);

    float3 color = make_float3(1.0f - viewColor.x, 1.0f - viewColor.y, 1.0f - viewColor.z);

    colorVomiKernel<<<gridSize, blockSize>>>(viewProbability, color, totalViewedVolume, gVolumeDataDims, gdColorVomi);
    CUT_CHECK_ERROR( "color vomi kernel failed" );

    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    float elapsedTime = 0.0f;
    cudaEventElapsedTime(&elapsedTime, start, stop);

    std::cout << "CVoMI: " << elapsedTime << " ms" << std::endl;

    cudaEventDestroy(start);
    cudaEventDestroy(stop);
}
*/


QVector<float> cviicGetImi()
{
    QVector<float> imi( gIntensityRange );
    CUDA_SAFE_CALL( cudaMemcpy(reinterpret_cast<void*>(imi.data()), reinterpret_cast<void*>(gdImi), gIntensityRange * sizeof(float), cudaMemcpyDeviceToHost) );
    return imi;
}


/*
QVector<Vector3Float> cvicGetColorVomi()
{
    QVector<Vector3Float> colorVomi( gVolumeDataSize );
    CUDA_SAFE_CALL( cudaMemcpy(reinterpret_cast<void*>(colorVomi.data()), reinterpret_cast<void*>(gdColorVomi), gVolumeDataSize * sizeof(float3), cudaMemcpyDeviceToHost) );
    return colorVomi;
}
*/


void cviicCleanupImi()
{
    //if (gdImi)
    {
        CUDA_SAFE_CALL( cudaFree(gdImi) );
    }

    /*
    if (gdColorVomi)
    {
        CUDA_SAFE_CALL( cudaFree(gdColorVomi) );
    }
    */
}
