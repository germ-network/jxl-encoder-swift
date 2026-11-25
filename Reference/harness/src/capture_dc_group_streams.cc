#include "capture_dc_group_streams.h"

#include <memory>

#include "lib/jxl/base/status.h"
#include "lib/jxl/dec_ans.h"
#include "lib/jxl/dec_bit_reader.h"
#include "lib/jxl/dec_cache.h"
#include "lib/jxl/dec_modular.h"
#include "lib/jxl/fields.h"
#include "lib/jxl/modular/encoding/dec_ma.h"
#include "lib/jxl/modular/encoding/encoding.h"
#include "lib/jxl/modular/modular_image.h"

namespace harness {
namespace {

JxlMemoryManager *Manager() {
  static JxlMemoryManager manager = [] {
    JxlMemoryManager m;
    if (!jxl::MemoryManagerInit(&m, nullptr))
      std::abort();
    return m;
  }();
  return &manager;
}

// The part of ModularGenericDecompress that precedes the pixel data.
bool ReadPrelude(jxl::BitReader *br, const jxl::Image &image,
                 LocalModularStream *out) {
  jxl::GroupHeader header;
  if (!jxl::Bundle::Read(br, &header))
    return false;
  if (header.use_global_tree)
    return true;
  uint64_t max_tree_size = 1024;
  for (const auto &channel : image.channel)
    max_tree_size += static_cast<uint64_t>(channel.w) * channel.h;
  max_tree_size = std::min<uint64_t>(1 << 20, max_tree_size);
  jxl::Tree tree;
  if (!jxl::DecodeTree(Manager(), br, &tree, max_tree_size))
    return false;
  jxl::ANSCode code;
  std::vector<uint8_t> context_map;
  if (!jxl::DecodeHistograms(Manager(), br, (tree.size() + 1) / 2, &code,
                             &context_map))
    return false;
  out->local = true;
  out->tree_node_count = tree.size();
  for (const auto &node : tree) {
    out->tree_nodes.insert(
        out->tree_nodes.end(),
        {node.property, node.splitval, node.lchild, node.rchild,
         static_cast<int>(node.predictor), node.predictor_offset,
         node.multiplier});
  }
  out->histogram_count = code.use_prefix_code ? code.huffman_data.size()
                                              : code.uint_config.size();
  return true;
}

void Skip(jxl::BitReader *br, size_t bits) {
  while (bits > 0) {
    const size_t step = std::min<size_t>(bits, 32);
    br->Refill();
    br->ReadBits(step);
    bits -= step;
  }
}

} // namespace

namespace {
jxl::Status Capture(const DecodedFrame &frame,
                    std::vector<DCGroupStreams> *groups) {
  const auto &shared = *frame.state->shared;
  const auto &layout = frame.entropy_layout;
  const size_t depth = 8;
  for (size_t group = 0; group < layout.num_dc_groups; ++group) {
    const LayoutSection *section = nullptr;
    for (const auto &candidate : layout.sections)
      if (candidate.id == 1 + group)
        section = &candidate;
    if (section == nullptr)
      return false;
    const jxl::Rect r = shared.frame_dim.DCGroupRect(group);
    const jxl::Bytes bytes(frame.codestream.data() + section->offset,
                           section->size);
    const size_t dc_id = jxl::ModularStreamId::VarDCTDC(group).ID(shared.frame_dim);
    const size_t meta_id =
        jxl::ModularStreamId::ACMetadata(group).ID(shared.frame_dim);

    auto make_dc_image = [&]() {
      return jxl::Image::Create(Manager(), r.xsize(), r.ysize(), depth, 3);
    };
    DCGroupStreams streams;
    // Prelude of the DC stream.
    {
      jxl::BitReader reader(bytes);
      reader.Refill();
      reader.ReadFixedBits<2>();
      JXL_ASSIGN_OR_RETURN(jxl::Image image, make_dc_image());
      bool ok = ReadPrelude(&reader, image, &streams.dc);
      (void)reader.Close();
      if (!ok)
        return false;
    }
    if (!streams.dc.local) {
      groups->push_back(std::move(streams));
      continue;
    }
    // Decode the whole DC stream to find where the metadata stream starts.
    size_t consumed;
    {
      jxl::BitReader reader(bytes);
      reader.Refill();
      reader.ReadFixedBits<2>();
      JXL_ASSIGN_OR_RETURN(jxl::Image image, make_dc_image());
      jxl::ModularOptions options;
      if (!jxl::ModularGenericDecompress(&reader, image, nullptr, dc_id,
                                         &options, false))
        return false;
      const size_t upper_bound = r.xsize() * r.ysize();
      reader.Refill();
      const size_t count_bits = jxl::CeilLog2Nonzero(upper_bound);
      const size_t count = reader.ReadBits(count_bits) + 1;
      consumed = reader.TotalBitsConsumed();
      (void)reader.Close();
      // Metadata stream layout, as in DecodeAcMetadata.
      jxl::BitReader meta(bytes);
      Skip(&meta, consumed);
      JXL_ASSIGN_OR_RETURN(
          jxl::Image meta_image,
          jxl::Image::Create(Manager(), r.xsize(), r.ysize(), depth, 4));
      jxl::Rect cr(r.x0() >> 3, r.y0() >> 3, (r.xsize() + 7) >> 3,
                   (r.ysize() + 7) >> 3);
      for (int c = 0; c < 2; ++c) {
        JXL_ASSIGN_OR_RETURN(
            meta_image.channel[c],
            jxl::Channel::Create(Manager(), cr.xsize(), cr.ysize(), 3, 3));
      }
      JXL_ASSIGN_OR_RETURN(
          meta_image.channel[2],
          jxl::Channel::Create(Manager(), count, 2, 0, 0));
      bool ok = ReadPrelude(&meta, meta_image, &streams.metadata);
      (void)meta.Close();
      (void)meta_id;
      if (!ok)
        return false;
    }
    groups->push_back(std::move(streams));
  }
  return true;
}
} // namespace

bool CaptureDCGroupStreams(const DecodedFrame &frame,
                           std::vector<DCGroupStreams> *groups) {
  return Capture(frame, groups);
}

} // namespace harness
