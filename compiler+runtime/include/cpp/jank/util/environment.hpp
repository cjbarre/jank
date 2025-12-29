#pragma once

#include <jtl/immutable_string.hpp>

namespace jank::util
{
  jtl::immutable_string const &user_home_dir();
  jtl::immutable_string const &user_cache_dir(jtl::immutable_string const &binary_version);
  jtl::immutable_string const &user_config_dir();
  jtl::immutable_string const &binary_cache_dir(jtl::immutable_string const &binary_version);

  jtl::immutable_string const &binary_version();

  jtl::immutable_string process_path();
  jtl::immutable_string process_dir();

  jtl::immutable_string resource_dir();

  void add_system_flags(std::vector<char const *> &args);

  /* Creates a unique temporary file with the given prefix.
   * Returns the path to the created file. The file is created but empty.
   * Cross-platform: uses mkstemp on Unix, GetTempFileName on Windows. */
  std::string make_temp_file(std::string const &prefix);
}
