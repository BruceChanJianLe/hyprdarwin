#include "hd_shim.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
    void *owner;
    long long remaining;
} HDState;

static hd_handler_fn g_handler = NULL;

#define HD_HOOK_STRIDE 1000

static HDState *state_of(lua_State *L) {
    return *(HDState **)lua_getextraspace(L);
}

void hd_set_handler(hd_handler_fn fn) { g_handler = fn; }

static int hd_trampoline(lua_State *L) {
    int fn_id = (int)lua_tointeger(L, lua_upvalueindex(1));
    int results = g_handler ? g_handler(L, fn_id) : 0;
    if (results == HD_RAISE) {
        if (lua_type(L, -1) == LUA_TSTRING) {
            luaL_where(L, 1);
            lua_insert(L, -2);
            lua_concat(L, 2);
        }
        return lua_error(L);
    }
    if (results == HD_RAISE_RAW) {
        return lua_error(L);
    }
    return results;
}

void hd_push_builtin(lua_State *L, int fn_id, const char *name) {
    lua_pushinteger(L, fn_id);
    if (name) {
        lua_pushstring(L, name);
    } else {
        lua_pushnil(L);
    }
    lua_pushcclosure(L, hd_trampoline, 2);
}

/* load(chunk [, chunkname [, mode [, env]]]) restricted to string chunks in
 * text mode: precompiled bytecode can crash the VM. */
static int hd_safe_load(lua_State *L) {
    size_t length = 0;
    const char *chunk = lua_tolstring(L, 1, &length);
    if (chunk == NULL || lua_type(L, 1) != LUA_TSTRING) {
        luaL_pushfail(L);
        lua_pushliteral(L, "load: only string chunks are supported in hyprdarwin");
        return 2;
    }
    const char *chunkname = luaL_optstring(L, 2, "=(load)");
    int env = !lua_isnone(L, 4) ? 4 : 0;
    int status = luaL_loadbufferx(L, chunk, length, chunkname, "t");
    if (status != LUA_OK) {
        luaL_pushfail(L);
        lua_insert(L, -2);
        return 2;
    }
    if (env != 0) {
        lua_pushvalue(L, env);
        if (!lua_setupvalue(L, -2, 1)) {
            lua_pop(L, 1);
        }
    }
    return 1;
}

static void open_lib(lua_State *L, const char *name, lua_CFunction open) {
    luaL_requiref(L, name, open, 1);
    lua_pop(L, 1);
}

static void clear_field(lua_State *L, const char *table, const char *field) {
    if (lua_getglobal(L, table) == LUA_TTABLE) {
        lua_pushnil(L);
        lua_setfield(L, -2, field);
    }
    lua_pop(L, 1);
}

lua_State *hd_newstate(void *owner) {
    lua_State *L = luaL_newstate();
    if (L == NULL) {
        return NULL;
    }
    HDState *state = calloc(1, sizeof(HDState));
    if (state == NULL) {
        lua_close(L);
        return NULL;
    }
    state->owner = owner;
    *(HDState **)lua_getextraspace(L) = state;

    open_lib(L, LUA_GNAME, luaopen_base);
    open_lib(L, LUA_TABLIBNAME, luaopen_table);
    open_lib(L, LUA_STRLIBNAME, luaopen_string);
    open_lib(L, LUA_MATHLIBNAME, luaopen_math);
    open_lib(L, LUA_UTF8LIBNAME, luaopen_utf8);
    open_lib(L, LUA_COLIBNAME, luaopen_coroutine);
    open_lib(L, LUA_OSLIBNAME, luaopen_os);

    lua_pushnil(L);
    lua_setglobal(L, "dofile");
    lua_pushnil(L);
    lua_setglobal(L, "loadfile");
    lua_pushcfunction(L, hd_safe_load);
    lua_setglobal(L, "load");

    clear_field(L, LUA_OSLIBNAME, "execute");
    clear_field(L, LUA_OSLIBNAME, "exit");
    clear_field(L, LUA_OSLIBNAME, "remove");
    clear_field(L, LUA_OSLIBNAME, "rename");
    clear_field(L, LUA_OSLIBNAME, "setlocale");
    clear_field(L, LUA_OSLIBNAME, "tmpname");
    clear_field(L, LUA_STRLIBNAME, "dump");
    return L;
}

void hd_close(lua_State *L) {
    if (L == NULL) {
        return;
    }
    HDState *state = state_of(L);
    lua_close(L);
    free(state);
}

void *hd_owner(lua_State *L) {
    HDState *state = state_of(L);
    return state ? state->owner : NULL;
}

static void hd_budget_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    HDState *state = state_of(L);
    state->remaining -= HD_HOOK_STRIDE;
    if (state->remaining < 0) {
        luaL_error(L, "instruction budget exceeded (an endless loop in the config?)");
    }
}

void hd_set_budget(lua_State *L, long long instructions) {
    HDState *state = state_of(L);
    if (instructions <= 0) {
        lua_sethook(L, NULL, 0, 0);
        return;
    }
    state->remaining = instructions;
    lua_sethook(L, hd_budget_hook, LUA_MASKCOUNT, HD_HOOK_STRIDE);
}

int hd_load_file(lua_State *L, const char *path, const char *chunkname) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        lua_pushfstring(L, "cannot open %s", path);
        return LUA_ERRFILE;
    }
    luaL_Buffer buffer;
    luaL_buffinit(L, &buffer);
    char chunk[4096];
    size_t read;
    while ((read = fread(chunk, 1, sizeof(chunk), file)) > 0) {
        luaL_addlstring(&buffer, chunk, read);
    }
    int failed = ferror(file);
    fclose(file);
    if (failed) {
        luaL_pushresult(&buffer);
        lua_pop(L, 1);
        lua_pushfstring(L, "cannot read %s", path);
        return LUA_ERRFILE;
    }
    luaL_pushresult(&buffer);
    size_t length = 0;
    const char *text = lua_tolstring(L, -1, &length);
    /* skip a leading "#!" line like lua.c does */
    const char *start = text;
    if (length > 0 && text[0] == '#') {
        while ((size_t)(start - text) < length && *start != '\n') {
            start++;
        }
    }
    int status = luaL_loadbufferx(L, start, length - (size_t)(start - text), chunkname, "t");
    lua_remove(L, -2);
    return status;
}

int hd_load_buffer(lua_State *L, const char *buffer, size_t length, const char *chunkname) {
    return luaL_loadbufferx(L, buffer, length, chunkname, "t");
}

static int hd_message_handler(lua_State *L) {
    if (lua_type(L, 1) == LUA_TSTRING) {
        return 1;
    }
    if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING) {
        return 1;
    }
    lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
    return 1;
}

int hd_pcall(lua_State *L, int nargs, int nresults) {
    int base = lua_gettop(L) - nargs;
    lua_pushcfunction(L, hd_message_handler);
    lua_insert(L, base);
    int status = lua_pcall(L, nargs, nresults, base);
    lua_remove(L, base);
    return status;
}

int hd_upvalueindex(int i) { return lua_upvalueindex(i); }
int hd_registryindex(void) { return LUA_REGISTRYINDEX; }
void hd_pop(lua_State *L, int n) { lua_pop(L, n); }
void hd_newtable(lua_State *L) { lua_newtable(L); }
void hd_insert(lua_State *L, int idx) { lua_insert(L, idx); }
void hd_remove(lua_State *L, int idx) { lua_remove(L, idx); }
int hd_ref(lua_State *L) { return luaL_ref(L, LUA_REGISTRYINDEX); }
void hd_unref(lua_State *L, int ref) { luaL_unref(L, LUA_REGISTRYINDEX, ref); }
void hd_getref(lua_State *L, int ref) { lua_rawgeti(L, LUA_REGISTRYINDEX, ref); }
