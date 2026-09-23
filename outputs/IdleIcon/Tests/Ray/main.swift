import AppKit
import MetalKit
import simd
let gpu=MTLCreateSystemDefaultDevice()!
guard gpu.supportsRaytracingFromRender else {print("SKIP: hardware ray tracing unavailable");exit(0)}
let combined=try gpu.makeLibrary(source:IconRenderer.shader+IconRenderer.rayShader,options:nil)
let descriptor=MTLRenderPipelineDescriptor()
descriptor.vertexFunction=combined.makeFunction(name:"vertex_main")
descriptor.fragmentFunction=combined.makeFunction(name:"fragment_ray")
descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
descriptor.depthAttachmentPixelFormat = .depth32Float
descriptor.rasterSampleCount=gpu.supportsTextureSampleCount(4) ? 4 : 1
_ = try gpu.makeRenderPipelineState(descriptor:descriptor)
print("PASS: multi-light hardware-ray fragment pipeline compiles")
let n=128
var pixels=[UInt8](repeating:0,count:n*n*4)
for y in 0..<n {for x in 0..<n {
    let r=hypot(Double(x)-63.5,Double(y)-63.5)
    if r>20 && r<52 {for c in 0..<4 {pixels[(y*n+x)*4+c]=255}}
}}
let cut=CutoutImage(size:n,pixels:pixels,method:"ring",retainedFraction:1)
let asset=try RenderAsset.make(cut,device:gpu)
let structure=asset.rayStructure!
let source="""
#include <metal_stdlib>
using namespace metal;
using namespace raytracing;
kernel void trace(acceleration_structure<> scene [[buffer(0)]],device float *out [[buffer(1)]],uint id [[thread_position_in_grid]]) {
    float x=id==0 ? 0.0 : 0.7;
    intersector<> i;
    ray r(float3(x,0,1),float3(0,0,-1));
    auto hit=i.intersect(r,scene);
    out[id]=hit.type==intersection_type::triangle ? hit.distance : -1.0;
}
"""
let library=try gpu.makeLibrary(source:source,options:nil)
let pipeline=try gpu.makeComputePipelineState(function:library.makeFunction(name:"trace")!)
let output=gpu.makeBuffer(length:2*MemoryLayout<Float>.stride,options:.storageModeShared)!
let command=gpu.makeCommandQueue()!.makeCommandBuffer()!
let encoder=command.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline);encoder.setAccelerationStructure(structure,bufferIndex:0);encoder.setBuffer(output,offset:0,index:1)
encoder.dispatchThreads(MTLSize(width:2,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:2,height:1,depth:1))
encoder.endEncoding();command.commit();command.waitUntilCompleted()
let result=output.contents().bindMemory(to:Float.self,capacity:2)
precondition(command.status == .completed && result[0]<0 && result[1]>0,"Ray intersection must leave icon hole transparent and hit solid ring")
print("PASS: hardware rays pass through icon hole and hit the solid contour; distances",result[0],result[1])
print("AS bytes",structure.allocatedSize)
