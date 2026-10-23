#!/usr/bin/env python3
"""cid_patch.py SWS_SRC - kernel-optim R3c "content ids": SwiftShader keys its JIT routine caches (pixel / vertex / setup,
compute programs) by per-object SERIAL ids of the SPIR-V binary and of the pipeline layout, so the same shader + layout
created again (another pipeline, another page) is JIT-compiled again. R3b measured 559 pixel-routine compiles for 71
distinct (code, state) pairs on 136 drafts. This patch gives equal CONTENT the same id:
  - SpirvBinary::kopt_canonicalize(): id = first id ever given to this exact word sequence (std::map, exact compare, no
    hashing -> no collision risk); called when a Spirv/SpirvShader object is built (content final there; the optimizer
    fills a default-constructed binary after its serial id was taken).
  - PipelineLayout identifier = first id given to the same layout content: per set the binding array (descriptor type,
    offset, count; dynamic offset indices follow from these) + push constant ranges. That is everything PipelineLayout
    stores and everything routine generation reads from it.
Equal ids now mean equal code inputs, so a cache hit returns the routine the miss would have built (class A by design;
verified by decoded-pixel identity). Every anchor is asserted."""
import sys


def patch(root, rel, old, new):
    p = f"{root}/{rel}"
    t = open(p).read()
    assert t.count(old) == 1, (rel, old[:70], t.count(old))
    open(p, "w").write(t.replace(old, new))


def main():
    r = sys.argv[1] + "/src"
    patch(r, "Pipeline/SpirvBinary.hpp", "\tvoid mapOptimizedIdentifier(const SpirvBinary &unoptimized);\n",
          "\tvoid mapOptimizedIdentifier(const SpirvBinary &unoptimized);\n\n"
          "\t// kopt: identifier = the first identifier given to this exact word sequence (content-keyed routine caches).\n"
          "\tvoid kopt_canonicalize();\n")
    patch(r, "Pipeline/SpirvBinary.cpp", '#include "SpirvBinary.hpp"\n',
          '#include "SpirvBinary.hpp"\n\n#include <map>\n#include <mutex>\n')
    patch(r, "Pipeline/SpirvBinary.cpp", "}  // namespace sw",
          "void SpirvBinary::kopt_canonicalize()\n{\n"
          "\tstatic std::mutex mutex;\n"
          "\tstatic std::map<std::vector<uint32_t>, uint32_t> ids;\n"
          "\tstd::lock_guard<std::mutex> lock(mutex);\n"
          "\tauto it = ids.find(*this);\n"
          "\tif(it != ids.end())\n\t{\n\t\tidentifier = it->second;\n\t\treturn;\n\t}\n"
          "\tidentifier = serialCounter++;\n"
          "\tids.emplace(*this, identifier);\n"
          "}\n\n}  // namespace sw")
    patch(r, "Pipeline/SpirvShader.cpp", "    , outputs{ MAX_INTERFACE_COMPONENTS }\n{\n\tASSERT(insns.size() > 0);\n",
          "    , outputs{ MAX_INTERFACE_COMPONENTS }\n{\n\tASSERT(insns.size() > 0);\n\tthis->insns.kopt_canonicalize();  // kopt: content id\n")
    patch(r, "Vulkan/VkPipelineLayout.cpp",
          "static std::atomic<uint32_t> layoutIdentifierSerial = { 1 };  // Start at 1. 0 is invalid/void layout.\n",
          "static std::atomic<uint32_t> layoutIdentifierSerial = { 1 };  // Start at 1. 0 is invalid/void layout.\n\n"
          "// kopt: the same layout content gets the same identifier (content-keyed routine caches).\n"
          "static uint32_t koptLayoutIdentifier(const VkPipelineLayoutCreateInfo *pCreateInfo)\n{\n"
          "\tstd::vector<uint32_t> key = { pCreateInfo->setLayoutCount, pCreateInfo->pushConstantRangeCount };\n"
          "\tfor(uint32_t i = 0; i < pCreateInfo->setLayoutCount; i++)\n\t{\n"
          "\t\tif(pCreateInfo->pSetLayouts[i] == VK_NULL_HANDLE)\n\t\t{\n\t\t\tkey.push_back(0xFFFFFFFFu);\n\t\t\tcontinue;\n\t\t}\n"
          "\t\tconst vk::DescriptorSetLayout *setLayout = vk::Cast(pCreateInfo->pSetLayouts[i]);\n"
          "\t\tuint32_t n = setLayout->getBindingsArraySize();\n"
          "\t\tkey.push_back(n);\n"
          "\t\tfor(uint32_t j = 0; j < n; j++)\n\t\t{\n"
          "\t\t\tkey.push_back(static_cast<uint32_t>(setLayout->getDescriptorType(j)));\n"
          "\t\t\tkey.push_back(setLayout->getBindingOffset(j));\n"
          "\t\t\tkey.push_back(setLayout->getDescriptorCount(j));\n\t\t}\n\t}\n"
          "\tfor(uint32_t i = 0; i < pCreateInfo->pushConstantRangeCount; i++)\n\t{\n"
          "\t\tkey.push_back(pCreateInfo->pPushConstantRanges[i].stageFlags);\n"
          "\t\tkey.push_back(pCreateInfo->pPushConstantRanges[i].offset);\n"
          "\t\tkey.push_back(pCreateInfo->pPushConstantRanges[i].size);\n\t}\n"
          "\tstatic std::mutex mutex;\n"
          "\tstatic std::map<std::vector<uint32_t>, uint32_t> ids;\n"
          "\tstd::lock_guard<std::mutex> lock(mutex);\n"
          "\tauto it = ids.find(key);\n"
          "\tif(it != ids.end())\n\t{\n\t\treturn it->second;\n\t}\n"
          "\tuint32_t id = layoutIdentifierSerial++;\n"
          "\tids.emplace(key, id);\n"
          "\treturn id;\n}\n")
    patch(r, "Vulkan/VkPipelineLayout.cpp", "    : identifier(layoutIdentifierSerial++)\n",
          "    : identifier(koptLayoutIdentifier(pCreateInfo))\n")
    p = f"{r}/Vulkan/VkPipelineLayout.cpp"
    t = open(p).read()
    first = t.index("#include")
    t = t[:first] + "#include <map>\n#include <mutex>\n#include <vector>\n" + t[first:]
    open(p, "w").write(t)
    print("cid patch ok")


if __name__ == "__main__":
    main()
