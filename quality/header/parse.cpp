/* Does the same header parse as C++17, and does its `extern "C"` guard hold?
 *
 * A C++ host is the ordinary case for this ABI — a game, an editor, a plugin —
 * and it is the case a C-only gate cannot speak for. C++ rejects things C99
 * accepts: an implicit `void *` conversion, a name that collides with a keyword,
 * a struct tag used where C++ wants the type. And if the `#ifdef __cplusplus`
 * guard is ever broken, every symbol here gets mangled and the host's link
 * fails with a name nobody typed.
 *
 * So the probe takes the address of an entry from each plane. That is the
 * assertion the guard is under: a mangled declaration and a C declaration are
 * different symbols, and only one of them has this type. */

#include <cstddef>

#include "irgx.h"

namespace {

using compile_fn = int32_t (*)(const uint8_t *, size_t, uint32_t, irgx_regex **);
using walk_fn = int32_t (*)(const irgx_walk_spec *, irgx_walk **);

static_assert(sizeof(irgx_fault) > 0, "the fault channel must be a complete type");
static_assert(sizeof(irgx_match) > 0, "a match must be a complete type");
static_assert(sizeof(irgx_schema) > 0, "the row schema must be a complete type");

}  // namespace

int irgx_header_probe_cpp17();

int irgx_header_probe_cpp17()
{
    compile_fn compile = &irgx_compile;
    walk_fn walk = &irgx_walk_open;
    return (compile != nullptr) + (walk != nullptr);
}
