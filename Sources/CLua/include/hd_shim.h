// Small C layer between Swift and Lua.
//
// Swift cannot call Lua's function-like macros, and it must never be unwound
// by lua_error's longjmp. Every hl.* builtin is therefore the same C
// trampoline: it calls the Swift handler, and when the handler reports an
// error the trampoline raises it from C, after Swift has returned.

#ifndef HD_SHIM_H
#define HD_SHIM_H

#include <stddef.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/// Results of a handler: >= 0 is the number of values pushed. HD_RAISE means
/// an error message is on top of the stack and should get a "file:line:"
/// prefix; HD_RAISE_RAW raises the value on top unchanged.
#define HD_RAISE (-1)
#define HD_RAISE_RAW (-2)

typedef int (*hd_handler_fn)(lua_State *L, int fn_id);

/// One process-wide handler; the owner pointer of each state routes the call.
void hd_set_handler(hd_handler_fn fn);

/// A fresh sandboxed state: base (without dofile/loadfile, and with a
/// text-only load), table, string, math, utf8, coroutine, and an os table
/// reduced to clock/date/difftime/getenv/time. No io, package or debug.
lua_State *hd_newstate(void *owner);
void hd_close(lua_State *L);
void *hd_owner(lua_State *L);

/// Push a builtin closure: upvalue 1 is fn_id, upvalue 2 is name (or nil).
void hd_push_builtin(lua_State *L, int fn_id, const char *name);

/// Instruction budget for everything that runs until the next call.
/// instructions <= 0 removes the limit.
void hd_set_budget(lua_State *L, long long instructions);

/// Load a text chunk from a file or a buffer (binary chunks are refused).
int hd_load_file(lua_State *L, const char *path, const char *chunkname);
int hd_load_buffer(lua_State *L, const char *buffer, size_t length, const char *chunkname);

/// lua_pcall with a message handler that turns non-string errors into text.
int hd_pcall(lua_State *L, int nargs, int nresults);

// Wrappers for API macros.
int hd_upvalueindex(int i);
int hd_registryindex(void);
void hd_pop(lua_State *L, int n);
void hd_newtable(lua_State *L);
void hd_insert(lua_State *L, int idx);
void hd_remove(lua_State *L, int idx);
int hd_ref(lua_State *L);
void hd_unref(lua_State *L, int ref);
void hd_getref(lua_State *L, int ref);

#endif
