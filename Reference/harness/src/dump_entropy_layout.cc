#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <utility>
#include <vector>

#include <string>

#include "capture_dc_group_streams.h"
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

  // The AC global code: its histogram count, prefix/ANS and the context map
  // over every histogram set.
  const auto &ac_code = frame.state->code[0];
  const auto &ac_map = frame.state->context_map[0];
  out.Integers("entropy_layout.ac.use_prefix_code",
               {ac_code.use_prefix_code ? 1 : 0});
  out.Integers("entropy_layout.ac.histogram_count",
               {static_cast<int64_t>(ac_code.use_prefix_code
                                         ? ac_code.huffman_data.size()
                                         : ac_code.uint_config.size())});
  out.Integers("entropy_layout.ac.context_map",
               std::vector<int64_t>(ac_map.begin(), ac_map.end()));

  // Local modular trees and data-code histogram counts, per DC group.
  std::vector<DCGroupStreams> streams;
  if (!CaptureDCGroupStreams(frame, &streams)) {
    std::fprintf(stderr, "dump entropy_layout: DC group streams do not parse\n");
    std::exit(1);
  }
  for (size_t group = 0; group < streams.size(); ++group) {
    const std::string prefix =
        "entropy_layout.dc_group." + std::to_string(group) + ".";
    const std::pair<const char *, const LocalModularStream *> kinds[] = {
        {"dc", &streams[group].dc}, {"metadata", &streams[group].metadata}};
    for (const auto &kind : kinds) {
      const std::string name = prefix + kind.first;
      out.Integers(name + ".local", {kind.second->local ? 1 : 0});
      out.Integers(name + ".tree_node_count",
                   {static_cast<int64_t>(kind.second->tree_node_count)});
      out.Integers(name + ".tree_nodes", kind.second->tree_nodes);
      out.Integers(name + ".histogram_count",
                   {static_cast<int64_t>(kind.second->histogram_count)});
    }
  }
}

const RegisterDumpCategory kRegister({"entropy_layout", DumpEntropyLayout});

} // namespace
} // namespace harness
