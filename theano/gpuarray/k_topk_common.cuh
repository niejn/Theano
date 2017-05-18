// modified from pytorch
// https://github.com/pytorch/pytorch/master/blob/torch/lib/THC/THCTensorTopK.cuh
// original license below:
/*
Copyright (c) 2016-     Facebook, Inc            (Adam Paszke)
Copyright (c) 2014-     Facebook, Inc            (Soumith Chintala)
Copyright (c) 2011-2014 Idiap Research Institute (Ronan Collobert)
Copyright (c) 2012-2014 Deepmind Technologies    (Koray Kavukcuoglu)
Copyright (c) 2011-2012 NEC Laboratories America (Koray Kavukcuoglu)
Copyright (c) 2011-2013 NYU                      (Clement Farabet)
Copyright (c) 2006-2010 NEC Laboratories America (Ronan Collobert, Leon Bottou, Iain Melvin, Jason Weston)
Copyright (c) 2006      Idiap Research Institute (Samy Bengio)
Copyright (c) 2001-2004 Idiap Research Institute (Ronan Collobert, Samy Bengio, Johnny Mariethoz)

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

3. Neither the names of Facebook, Deepmind Technologies, NYU, NEC Laboratories America
   and IDIAP Research Institute nor the names of its contributors may be
   used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
*/


#if __CUDA_ARCH__ < 350
#define __ldg(ptr) (*(ptr))
#endif


template <typename T>
struct RadixConfig {
// Converts a type (maybe float) to an integer representation with the same
// sorting; i.e., for floats f1, f2:
// if f1 < f2 then convert(f1) < convert(f2)
// We use this to enable radix selection of floating-point values.
// This also gives a relative order for NaNs, but that's ok, as they
// will all be adjacent
  typedef T RadixType;
  static inline __device__ RadixType convert(T v) {
      return v;
  }

  static inline __device__ float deconvert(RadixType v) {
      return v;
  }
};

template <>
struct RadixConfig<ga_float> {
  typedef ga_uint RadixType;

  static inline __device__ RadixType convert(ga_float v) {
    RadixType x = __float_as_int(v);
    RadixType mask = (x & 0x80000000) ? 0xffffffff : 0x80000000;

    return (x ^ mask);
  }

  static inline __device__ ga_float deconvert(RadixType v) {
    RadixType mask = (v & 0x80000000) ? 0x80000000 : 0xffffffff;

    return __int_as_float(v ^ mask);
  }
};

template <>
struct RadixConfig<ga_double> {
  typedef ga_ulong RadixType;

  static inline __device__ RadixType convert(ga_double v) {
    RadixType x = __double_as_longlong(v);
    RadixType mask = -((x >> 63)) | 0x8000000000000000;
    return (x ^ mask);
  }

  static inline __device__ ga_double deconvert(RadixType v) {
    RadixType mask = ((v >> 63) - 1) | 0x8000000000000000;
    return __longlong_as_double(v ^ mask);
  }
};


template <>
struct RadixConfig<ga_byte> {
  typedef ga_ubyte RadixType;

  static inline __device__ RadixType convert(ga_byte v) {
    return 128u + v;
  }

  static inline __device__ ga_byte deconvert(RadixType v) {
    return v - 128;
  }
};

template <>
struct RadixConfig<ga_short> {
  typedef ga_ushort RadixType;

  static inline __device__ RadixType convert(ga_short v) {
    assert(sizeof(ga_short) == 2);
    return 32768u ^ v;
  }

  static inline __device__ ga_short deconvert(RadixType v) {
    return v - 32768;
  }
};

template <>
struct RadixConfig<ga_int> {
  typedef ga_uint RadixType;

  static inline __device__ RadixType convert(ga_int v) {
    assert(sizeof(int) == 4);
    return 2147483648u + v;
  }

  static inline __device__ ga_int deconvert(RadixType v) {
    return v - 2147483648u;
  }
};

template <>
struct RadixConfig<ga_long> {
  typedef ga_ulong RadixType;

  static inline __device__ RadixType convert(ga_long v) {
    assert(sizeof(ga_long) == 8);
    return 9223372036854775808ull + v;
  }

  static inline __device__ long long deconvert(RadixType v) {
    return v - 9223372036854775808ull;
  }
};

#define USE_HALF $use_half

#if USE_HALF == 1
// since ga_half is ushort, use macro to protect this part is necessary
template <>
struct RadixConfig<ga_half> {
  typedef ga_ushort RadixType;

  static inline __device__ RadixType convert(ga_half v) {
    RadixType mask = -(((RadixType)v >> 15)) | 0x8000;
    return (v ^ mask);
  }

  static inline __device__ ga_half deconvert(RadixType v) {
    RadixType mask = ((v >> 15) - 1) | 0x8000;
    return (ga_half)(v ^ mask);
  }
};
#endif // USE_HALF

// $$inp_t should be replaced in c_code
// we cannot use templated kernel because gpuarray API does not support it
#define NDIM            $ndim
#define INPUT_TYPE      $inp_t
#define INDEX_TYPE      $out_t
#define bitsof(T)       (sizeof(T)*8)
#define RADIX_BITS      2
#define RADIX_SIZE      (1<<RADIX_BITS)
#define RADIX_MASK(n)   ((RADIX_SIZE-1) << (n*RADIX_BITS))
#define RADIX_DIGITS(T) (bitsof(T)/RADIX_BITS)
#define radix_t         RadixConfig<INPUT_TYPE>::RadixType
#define WRITE_VALUE     $write_value
#define WRITE_INDEX     $write_index

#if RADIX_SIZE > 32
#error "RADIX_SIZE must be smaller than warp size (32)"
#endif

static inline __device__ ga_size binary_cumsum(
    int idx, int warp_id, int lane_id, ga_size* smem, bool value) {
    // cumsum within 1D thread block, which adds up `value` of all threads
    // whose id is *no greater than* the current thread
    // binary_cumsum(1, 0, 1, 0, 1) -> (1, 1, 2, 2, 3)

    // cumsum within warp
    ga_uint warp_bits = __ballot(value);
    ga_size warp_sum = __popc(((2<<lane_id)-1) & warp_bits);

    if (lane_id == 0)
        smem[warp_id] = __popc(warp_bits);

    local_barrier();

    // cumsum across warps in one thread
    if (idx == 0) {
        int current = 0;
        for (int i = 0; i < LDIM_0 / GA_WARP_SIZE; ++i) {
            ga_size v = smem[i];
            smem[i] = smem[i]+current;
            current = current+v;
        }
    }

    local_barrier();

    // load the carry from the preceding warp
    if (warp_id >= 1) {
        warp_sum = warp_sum+smem[warp_id - 1];
    }

    return warp_sum;
}

static inline __device__ ga_size binary_cumsum_exclusive(
    int idx, int warp_id, int lane_id, ga_size* smem, bool value) {
    // cumsum within 1D thread block, which adds up `value` of all threads
    // whose id is *less than* the current thread
    // binary_cumsum_excl(1, 0, 1, 0, 1) -> (0, 1, 1, 2, 2)

    // cumsum within warp
    ga_uint warp_bits = __ballot(value);
    ga_size warp_sum = __popc(((1<<lane_id)-1) & warp_bits);

    if (lane_id == 0)
        smem[warp_id] = __popc(warp_bits);

    local_barrier();

    // cumsum across warps in one thread
    if (idx == 0) {
        int current = 0;
        for (int i = 0; i < LDIM_0 / GA_WARP_SIZE; ++i) {
            ga_size v = smem[i];
            smem[i] = smem[i]+current;
            current = current+v;
        }
    }

    local_barrier();

    // load the carry from the preceding warp
    if (warp_id >= 1)
        warp_sum += smem[warp_id - 1];

    return warp_sum;
}

// apply raw(byte) offset to pointer
template <typename T>
static __device__ inline T* ptr_add(T *ptr, ga_ssize offset) {
    return (T*)((char*)ptr + offset);
}

// get array element using raw(byte) offset
template <typename T>
static __device__ inline T& ptr_at(T *ptr, ga_ssize offset) {
    return *((T*)((char*)ptr + offset));
}

// read array element using raw(byte) offset
template <typename T>
static __device__ inline T ptr_read(T *ptr, ga_ssize offset) {
    return __ldg(((T*)((char*)ptr + offset)));
}

