#pragma once

#include <Tempest/AbstractGraphicsApi>
#include <mutex>

#include <Metal/Metal.hpp>

namespace Tempest {
namespace Detail {

class MtSync : public AbstractGraphicsApi::Fence {
  public:
    MtSync();
    ~MtSync();

    void wait() override;
    bool wait(uint64_t time) override;
    void reset() override;
    void reset(MTL::CommandBufferStatus err);

    void signal();

  private:
    std::mutex               sync;
    std::condition_variable  cv;
    std::atomic_bool         hasWait{false};
    MTL::CommandBufferStatus status = MTL::CommandBufferStatusNotEnqueued;
    void propogateError();
  };

}
}
