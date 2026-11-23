#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "edge_cli.h"
#include "edge_environment.h"
#include "edge_environment_runtime.h"
#include "edge_napi_embedder_hooks.h"
#include "edge_runtime.h"
#include "node_api.h"
#include "unofficial_napi.h"

extern "C" char** uv_setup_args(int argc, char** argv);
extern "C" char* fx_edge_host_call(const char* name, const char* args);
extern "C" void fx_edge_host_free(char* reply);

static std::string Utf8(napi_env env, napi_value value) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) return {};
  std::string text(length, '\0');
  napi_get_value_string_utf8(env, value, text.data(), length + 1, &length);
  return text;
}

static napi_value HostCall(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 2) {
    napi_throw_type_error(env, nullptr, "fxHost.call needs a verb name and its JSON arguments");
    return nullptr;
  }
  const std::string name = Utf8(env, argv[0]);
  const std::string args = Utf8(env, argv[1]);
  char* reply = fx_edge_host_call(name.c_str(), args.c_str());
  napi_value out = nullptr;
  napi_create_string_utf8(env, reply != nullptr ? reply : "", NAPI_AUTO_LENGTH, &out);
  fx_edge_host_free(reply);
  return out;
}

static std::string WritePrelude(const char* prelude) {
  char path[] = "/tmp/fx-edge-prelude-XXXXXX";
  const int fd = mkstemp(path);
  if (fd < 0) return {};
  const size_t length = std::strlen(prelude);
  const bool written = write(fd, prelude, length) == static_cast<ssize_t>(length);
  close(fd);
  if (!written) {
    unlink(path);
    return {};
  }
  return path;
}

static bool InstallHost(napi_env env) {
  napi_value global = nullptr;
  napi_value host = nullptr;
  napi_value call = nullptr;
  return napi_get_global(env, &global) == napi_ok && napi_create_object(env, &host) == napi_ok &&
         napi_create_function(env, "call", NAPI_AUTO_LENGTH, HostCall, nullptr, &call) == napi_ok &&
         napi_set_named_property(env, host, "call", call) == napi_ok &&
         napi_set_named_property(env, global, "fxHost", host) == napi_ok;
}

extern "C" int fx_edge_run(int argc, char** argv, const char* prelude, const char* script) {
  uv_setup_args(argc, argv);
  EdgeInitializeCliProcess();
  std::string error;
  const std::vector<std::string> exec_argv;
  unofficial_napi_env_create_options create_options{};
  EdgeInitializeNapiEnvCreateOptions(&create_options);
  unofficial_napi_runtime_options runtime_options{};
  runtime_options.size = sizeof(runtime_options);
  runtime_options.version = UNOFFICIAL_NAPI_RUNTIME_OPTIONS_VERSION;
  napi_env env = nullptr;
  unofficial_napi_env_owner owner = nullptr;
  int code = 1;
  if (EdgeInitializeOpenSslForExecArgv(exec_argv, false, &error) &&
      unofficial_napi_configure_runtime(&runtime_options) == napi_ok &&
      unofficial_napi_create_env(8, &create_options, &env, &owner) == napi_ok &&
      EdgeAttachEnvironmentForRuntime(env) && InstallHost(env)) {
    const std::string prelude_path = WritePrelude(prelude);
    if (prelude_path.empty()) {
      error = "fx could not stage the edge prelude";
    } else {
      EdgeSetExecArgv({"--require", prelude_path});
      EdgeSetCurrentScriptPath(script);
      code = EdgeRunScriptFileWithLoop(env, script, &error, true);
      unlink(prelude_path.c_str());
    }
    EdgeEnvironmentRunCleanup(env);
    EdgeEnvironmentRunAtExitCallbacks(env);
    EdgeEnvironmentDetach(env);
  } else if (error.empty()) {
    error = "fx could not start the edgejs runtime";
  }
  if (owner != nullptr) unofficial_napi_release_env(owner, nullptr);
  if (!error.empty()) std::fprintf(stderr, "%s\n", error.c_str());
  return code;
}
