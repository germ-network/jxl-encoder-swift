#include <cstdint>
#include <vector>

#include "decoded_frame.h"
#include "registry.h"

namespace harness {
namespace {

void DumpEntropyLayout(const DecodedFrame &frame, SemanticDumpWriter &out) {
  const auto &layout = frame.entropy_layout;
  out.Integers("entropy_layout.group_grid",
               {static_cast<int64_t>(layout.groups_x),
                static_cast<int64_t>(layout.groups_y)});
  out.Integers("entropy_layout.group_count",
               {static_cast<int64_t>(layout.num_groups)});
  out.Integers("entropy_layout.dc_group_count",
               {static_cast<int64_t>(layout.num_dc_groups)});
  out.Integers("entropy_layout.pass_count",
               {static_cast<int64_t>(layout.num_passes)});
  out.Integers("entropy_layout.histogram_set_count",
               {static_cast<int64_t>(layout.num_histograms)});
  out.Integers("entropy_layout.selector_bits",
               {static_cast<int64_t>(layout.selector_bits)});
  out.Integers("entropy_layout.modular_tree.node_count",
               {static_cast<int64_t>(layout.modular_tree_node_count)});
  out.Integers("entropy_layout.modular_tree.nodes", layout.modular_tree_nodes);

  std::vector<int64_t> section_ids;
  std::vector<int64_t> section_indices;
  std::vector<int64_t> section_offsets;
  std::vector<int64_t> section_sizes;
  for (const auto &section : layout.sections) {
    section_ids.push_back(static_cast<int64_t>(section.id));
    section_indices.push_back(static_cast<int64_t>(section.index));
    section_offsets.push_back(static_cast<int64_t>(section.offset));
    section_sizes.push_back(static_cast<int64_t>(section.size));
  }
  out.Integers("entropy_layout.section_ids", section_ids);
  out.Integers("entropy_layout.section_indices", section_indices);
  out.Integers("entropy_layout.section_offsets", section_offsets);
  out.Integers("entropy_layout.section_sizes", section_sizes);

  std::vector<int64_t> selectors;
  for (const auto &selector : layout.selectors) {
    selectors.insert(selectors.end(),
                     {static_cast<int64_t>(selector.pass),
                      static_cast<int64_t>(selector.group),
                      static_cast<int64_t>(selector.section_id),
                      static_cast<int64_t>(selector.value)});
  }
  out.Integers("entropy_layout.ac_selectors", selectors);
}

const RegisterDumpCategory kRegister({"entropy_layout", DumpEntropyLayout});

} // namespace
} // namespace harness
