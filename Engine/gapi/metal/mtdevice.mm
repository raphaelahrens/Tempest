#if defined(TEMPEST_BUILD_METAL)

#include "mtdevice.h"
#include <Tempest/Log>

#include <Foundation/NSProcessInfo.h>

//#include <Metal/MTLPixelFormat.h>

using namespace Tempest;
using namespace Tempest::Detail;

static NsPtr<MTL::Device> mkDevice(const char* name) {
  if(name==nullptr)
    return NsPtr<MTL::Device>(MTL::CreateSystemDefaultDevice());

  auto dev = NsPtr<NS::Array>(MTL::CopyAllDevices());
  for(size_t i=0; i<dev->count(); ++i) {
    NS::Object*  at = dev->object(i);
    MTL::Device* d  = reinterpret_cast<MTL::Device*>(at);
    if(std::strcmp(name,d->name()->utf8String())==0) {
      return NsPtr<MTL::Device>(d);
      }
    }
  return NsPtr<MTL::Device>(nullptr);
  }

MtDevice::MtDevice(const char* name, bool validation)
  : impl(mkDevice(name)), samplers(*impl), validation(validation) {
  if(impl.get()==nullptr)
    throw std::system_error(Tempest::GraphicsErrc::NoDevice);

  queue = NsPtr<MTL::CommandQueue>(impl->newCommandQueue());
  if(queue.get()==nullptr)
    throw std::system_error(Tempest::GraphicsErrc::NoDevice);

  deductProps(prop,*impl);
  }

MtDevice::~MtDevice() {
  }

void MtDevice::waitIdle() {
  // TODO: verify, if this correct at all
  auto cmd = queue->commandBuffer();
  cmd->commit();
  cmd->waitUntilCompleted();
  }

void MtDevice::handleError(NS::Error *err) {
  if(err==nullptr)
    return;
#if !defined(NDEBUG)
  const char* e = err->localizedDescription()->utf8String();
  Log::d("NSError: \"",e,"\"");
#endif
  throw DeviceLostException();
  }

void MtDevice::deductProps(AbstractGraphicsApi::Props& prop, MTL::Device& dev) {
  SInt32 majorVersion = 0, minorVersion = 0;
  if([[NSProcessInfo processInfo] respondsToSelector:@selector(operatingSystemVersion)]) {
    NSOperatingSystemVersion ver = [[NSProcessInfo processInfo] operatingSystemVersion];
    majorVersion = ver.majorVersion;
    minorVersion = ver.minorVersion;
    }

  std::strncpy(prop.name,dev.name()->utf8String(),sizeof(prop.name));
  if(dev.hasUnifiedMemory())
    prop.type = DeviceType::Integrated; else
    prop.type = DeviceType::Discrete;

  // https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
  static const TextureFormat smp[] = {TextureFormat::R8,   TextureFormat::RG8,   TextureFormat::RGBA8,
                                      TextureFormat::R16,  TextureFormat::RG16,  TextureFormat::RGBA16,
                                      TextureFormat::R32F, TextureFormat::RG32F, TextureFormat::RGBA32F,
                                      TextureFormat::R11G11B10UF, TextureFormat::RGBA16F,
                                     };

  static const TextureFormat att[] = {TextureFormat::R8,   TextureFormat::RG8,   TextureFormat::RGBA8,
                                      TextureFormat::R16,  TextureFormat::RG16,  TextureFormat::RGBA16,
                                      TextureFormat::R32F, TextureFormat::RG32F, TextureFormat::RGBA32F,
                                      TextureFormat::R11G11B10UF, TextureFormat::RGBA16F,
                                     };

  static const TextureFormat sso[] = {TextureFormat::R8,   TextureFormat::RG8,   TextureFormat::RGBA8,
                                      TextureFormat::R16,  TextureFormat::RG16,  TextureFormat::RGBA16,
                                      TextureFormat::R32F, TextureFormat::RGBA32F,
                                      TextureFormat::R11G11B10UF, TextureFormat::RGBA16F,
                                     };

  static const TextureFormat ds[]  = {TextureFormat::Depth16, TextureFormat::Depth32F};

  uint64_t smpBit = 0, attBit = 0, dsBit = 0, storBit = 0;
  for(auto& i:smp)
    smpBit |= uint64_t(1) << uint64_t(i);
  for(auto& i:att)
    attBit |= uint64_t(1) << uint64_t(i);
  for(auto& i:sso)
    storBit  |= uint64_t(1) << uint64_t(i);
  for(auto& i:ds)
    dsBit  |= uint64_t(1) << uint64_t(i);

  if(dev.supportsBCTextureCompression()) {
    static const TextureFormat bc[] = {TextureFormat::DXT1, TextureFormat::DXT3, TextureFormat::DXT5};
    for(auto& i:bc)
      smpBit |= uint64_t(1) << uint64_t(i);
    }

  if(dev.depth24Stencil8PixelFormatSupported()) {
    static const TextureFormat ds[] = {TextureFormat::Depth24S8};
    for(auto& i:ds)
      dsBit  |= uint64_t(1) << uint64_t(i);
    }

  {
  /* NOTE1: https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf
   * > You must declare textures with depth formats as one of the following texture data types
   * > depth2d
   *
   * NOTE2: https://github.com/KhronosGroup/SPIRV-Cross/issues/529
   * It seems MSL and Metal validation-layer doesn't really care, if depth is sampled as texture2d<>
   *
   * Testing shows, that texture2d works on MacOS
  */
#ifdef __OSX__
  if(majorVersion>=11 || (majorVersion==10 && minorVersion>=11))
    smpBit |= uint64_t(1) << TextureFormat::Depth32F;
#else
  // no iOS, for Depth32F
#endif

#ifdef __OSX__
  if(majorVersion>=11 || (majorVersion==10 && minorVersion>=12))
    smpBit |= uint64_t(1) << TextureFormat::Depth16;
#else
  if(majorVersion>=13)
    smpBit |= uint64_t(1) << TextureFormat::Depth16;
#endif
  }

  prop.setSamplerFormats(smpBit);
  prop.setAttachFormats (attBit);
  prop.setDepthFormats  (dsBit);
  prop.setStorageFormats(storBit);

  prop.mrt.maxColorAttachments = 4;
  if(dev.supportsFamily(MTL::GPUFamilyApple2))
    prop.mrt.maxColorAttachments = 8;

  // https://developer.apple.com/documentation/metal/mtlrendercommandencoder/1515829-setvertexbuffer?language=objc
  prop.vbo.maxAttribs = 31;

#ifdef __IOS__
  prop.ubo .offsetAlign = 16;
  prop.ssbo.offsetAlign = 16;
#else
  prop.ubo .offsetAlign = 256; //assuming device-local memory
  prop.ssbo.offsetAlign = 16;
#endif

  // in fact there is no limit, just recomendation to submit less than 4kb of data
  prop.push.maxRange = 256;

  prop.compute.maxGroupSize.x = 512;
  prop.compute.maxGroupSize.y = 512;
  prop.compute.maxGroupSize.z = 512;
  if(dev.supportsFamily(MTL::GPUFamilyApple4)) {
    prop.compute.maxGroupSize.x = 1024;
    prop.compute.maxGroupSize.y = 1024;
    prop.compute.maxGroupSize.z = 1024;
    }

  prop.anisotropy    = true;
  prop.maxAnisotropy = 16;

#ifdef __IOS__
  if(dev.supportsFeatureSet(MTL::FeatureSet_iOS_GPUFamily3_v2))
    prop.tesselationShader = false;//true;
#else
  if(dev.supportsFeatureSet(MTL::FeatureSet_macOS_GPUFamily1_v2))
    prop.tesselationShader = false;//true;
#endif

#ifdef __IOS__
  prop.storeAndAtomicVs = false;
  prop.storeAndAtomicFs = false;
#else
  // TODO: verify
  prop.storeAndAtomicVs = false;
  prop.storeAndAtomicFs = false;
#endif

#ifdef __OSX__
  if(majorVersion>=12)
    prop.raytracing.rayQuery = dev.supportsRaytracingFromRender();
#endif

#ifdef __IOS__
  // TODO
#else
  if(dev.supportsFamily(MTL::GPUFamilyMetal3)) {
    //prop.meshlets.meshShader = true;
    prop.meshlets.maxGroups = prop.compute.maxGroups;
    prop.meshlets.maxGroupSize = prop.compute.maxGroupSize;
    }
#endif
  }

#endif
