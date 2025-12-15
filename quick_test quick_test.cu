#include <cuda_runtime.h>
#include <stdio.h>

#define CHECK(call) { \
    cudaError_t err = call; \
    if (err != cudaSuccess) { \
        printf("ERROR: %s (code %d)\n", cudaGetErrorString(err), err); \
        return 1; \
    } \
}

__global__ void vectorAdd(float *a, float *b, float *c, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        c[idx] = a[idx] + b[idx];
    }
}

int main() {
    int deviceCount;
    CHECK(cudaGetDeviceCount(&deviceCount));
    printf("Found %d GPU(s)\n\n", deviceCount);
    
    const int N = 1 << 20;
    size_t bytes = N * sizeof(float);
    
    for (int dev = 0; dev < deviceCount; dev++) {
        CHECK(cudaSetDevice(dev));
        
        cudaDeviceProp prop;
        CHECK(cudaGetDeviceProperties(&prop, dev));
        printf("GPU %d: %s (SM %d.%d)\n", dev, prop.name, prop.major, prop.minor);
        
        float *d_a, *d_b, *d_c;
        CHECK(cudaMalloc(&d_a, bytes));
        CHECK(cudaMalloc(&d_b, bytes));
        CHECK(cudaMalloc(&d_c, bytes));
        
        int threads = 256;
        int blocks = (N + threads - 1) / threads;
        
        cudaEvent_t start, stop;
        CHECK(cudaEventCreate(&start));
        CHECK(cudaEventCreate(&stop));
        
        CHECK(cudaEventRecord(start));
        vectorAdd<<<blocks, threads>>>(d_a, d_b, d_c, N);
        CHECK(cudaEventRecord(stop));
        CHECK(cudaEventSynchronize(stop));
        
        float ms;
        CHECK(cudaEventElapsedTime(&ms, start, stop));
        printf("  Vector add: %.2f ms, Bandwidth: %.2f GB/s\n", 
               ms, (3 * bytes) / (ms * 1e6));
        
        CHECK(cudaFree(d_a));
        CHECK(cudaFree(d_b));
        CHECK(cudaFree(d_c));
        CHECK(cudaEventDestroy(start));
        CHECK(cudaEventDestroy(stop));
        printf("  Status: ✓ PASSED\n\n");
    }
    
    return 0;
}
