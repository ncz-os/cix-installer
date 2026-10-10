/*
 * mali-shader-trace.c — LD_PRELOAD GL shader/link diagnostics (GLES2)
 *
 * Intercepts glCompileShader and glLinkProgram to dump shader source and
 * info logs to stderr. For diagnosing SceneFX shader failures under a
 * headless vendor Mali GL driver (running labwc).
 *
 * Build:  cc -shared -fPIC -o trace.so build/mali-shader-trace.c -ldl
 * Run:    LD_PRELOAD=./trace.so <app>
 *
 * No EGL initialization or mutation. No shader source rewriting.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <GLES2/gl2.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Unique per-entity IDs                                               */
/* ------------------------------------------------------------------ */

static pthread_mutex_t g_id_lock = PTHREAD_MUTEX_INITIALIZER;
static GLuint g_next_id = 1;

static GLuint next_id(void)
{
    GLuint id;
    pthread_mutex_lock(&g_id_lock);
    id = g_next_id++;
    pthread_mutex_unlock(&g_id_lock);
    return id;
}

/* ------------------------------------------------------------------ */
/* Real GL function pointers, resolved via dlsym(RTLD_NEXT, ...)       */
/* Every pointer is checked before use; NULL is never called.          */
/* ------------------------------------------------------------------ */

static pthread_once_t g_resolve_once = PTHREAD_ONCE_INIT;

static void *p_glCompileShader = NULL;
static void *p_glLinkProgram = NULL;
static void *p_glGetShaderiv = NULL;
static void *p_glGetShaderSource = NULL;
static void *p_glGetShaderInfoLog = NULL;
static void *p_glGetProgramiv = NULL;
static void *p_glGetProgramInfoLog = NULL;
static void *p_glGetString = NULL;

static void dump_gl_string(const char *label, GLenum name)
{
    if (!p_glGetString) {
        fprintf(stderr, "[shader-trace] %-12s: <glGetString unresolved>\n", label);
        return;
    }
    const GLubyte *(*orig_glGetString)(GLenum) =
        (const GLubyte *(*)(GLenum))p_glGetString;
    const GLubyte *s = orig_glGetString(name);
    fprintf(stderr, "[shader-trace] %-12s: %s\n", label, s ? (const char *)s : "(null)");
}

static void resolve_gl_funcs(void)
{
    struct {
        const char *name;
        void **slot;
    } table[] = {
        { "glCompileShader",      &p_glCompileShader },
        { "glLinkProgram",        &p_glLinkProgram },
        { "glGetShaderiv",        &p_glGetShaderiv },
        { "glGetShaderSource",    &p_glGetShaderSource },
        { "glGetShaderInfoLog",   &p_glGetShaderInfoLog },
        { "glGetProgramiv",       &p_glGetProgramiv },
        { "glGetProgramInfoLog",  &p_glGetProgramInfoLog },
        { "glGetString",          &p_glGetString },
        { NULL, NULL }
    };

    int ok = 1;
    for (int i = 0; table[i].name != NULL; i++) {
        *table[i].slot = dlsym(RTLD_NEXT, table[i].name);
        if (*table[i].slot == NULL) {
            fprintf(stderr, "[shader-trace] FATAL: dlsym(RTLD_NEXT, %s) failed: %s\n",
                    table[i].name, dlerror());
            ok = 0;
        }
    }

    if (!ok) {
        fprintf(stderr, "[shader-trace] aborting preload: required GL functions missing\n");
        abort();
    }
}

static void init_gl_funcs(void)
{
    pthread_once(&g_resolve_once, resolve_gl_funcs);
}

static void log_gl_context(void)
{
    init_gl_funcs();
    dump_gl_string("vendor",   GL_VENDOR);
    dump_gl_string("renderer", GL_RENDERER);
    dump_gl_string("version",  GL_VERSION);
}

/* ------------------------------------------------------------------ */
/* Query helpers (every pointer checked)                               */
/* ------------------------------------------------------------------ */

static GLint query_shader_iv(GLuint shader, GLenum pname)
{
    if (!p_glGetShaderiv)
        return -1;
    void (*orig)(GLuint, GLenum, GLint *) = (void (*)(GLuint, GLenum, GLint *))p_glGetShaderiv;
    GLint v = 0;
    orig(shader, pname, &v);
    return v;
}

static GLint query_program_iv(GLuint program, GLenum pname)
{
    if (!p_glGetProgramiv)
        return -1;
    void (*orig)(GLuint, GLenum, GLint *) = (void (*)(GLuint, GLenum, GLint *))p_glGetProgramiv;
    GLint v = 0;
    orig(program, pname, &v);
    return v;
}

static const char *shader_type_str(GLint type)
{
    switch (type) {
    case GL_VERTEX_SHADER:   return "vertex";
    case GL_FRAGMENT_SHADER: return "fragment";
    default:                 return "unknown";
    }
}

/* ------------------------------------------------------------------ */
/* Info log helper (single query+read, pointer-checked)                */
/* ------------------------------------------------------------------ */

static void dump_info_log(const char *label, void (*orig_fn)(GLuint, GLsizei, GLsizei *, GLchar *),
                          GLuint entity, GLsizei log_len)
{
    if (!orig_fn || log_len <= 0) {
        if (log_len <= 0)
            fprintf(stderr, "[shader-trace]   %s: (empty)\n", label);
        return;
    }

    GLchar *buf = (GLchar *)malloc((size_t)log_len + 1);
    if (buf == NULL) {
        fprintf(stderr, "[shader-trace]   %s: (malloc failed)\n", label);
        return;
    }
    GLsizei actual = 0;
    orig_fn(entity, log_len, &actual, buf);
    int n = actual < 0 ? 0 : actual;
    if (n > log_len)
        n = log_len;
    buf[n] = '\0';
    fprintf(stderr, "[shader-trace]   %s:\n%s\n", label, buf);
    free(buf);
}

/* ------------------------------------------------------------------ */
/* glGetShaderSource helper — full source dump, no rewriting           */
/* ------------------------------------------------------------------ */

static void dump_shader_source(GLuint shader)
{
    if (!p_glGetShaderSource || !p_glGetShaderiv)
        return;
    void (*orig)(GLuint, GLsizei, GLsizei *, GLchar *) =
        (void (*)(GLuint, GLsizei, GLsizei *, GLchar *))p_glGetShaderSource;

    /* Source length must come from GL_SHADER_SOURCE_LENGTH; the
     * glGetShaderSource length param is a buffer-size cap, not a
     * query-by-zero. */
    GLint slen = 0;
    void (*orig_iv)(GLuint, GLenum, GLint *) = (void (*)(GLuint, GLenum, GLint *))p_glGetShaderiv;
    orig_iv(shader, GL_SHADER_SOURCE_LENGTH, &slen);
    if (slen <= 0) {
        fprintf(stderr, "[shader-trace]   (shader source: empty)\n");
        return;
    }

    GLchar *buf = (GLchar *)malloc((size_t)slen + 1);
    if (buf == NULL) {
        fprintf(stderr, "[shader-trace]   (shader source: malloc failed)\n");
        return;
    }

    GLsizei actual = 0;
    orig(shader, slen, &actual, buf);
    if (actual <= 0) {
        fprintf(stderr, "[shader-trace]   (shader source: read failed)\n");
        free(buf);
        return;
    }

    int n = actual < 0 ? 0 : actual;
    if (n > slen)
        n = slen;
    buf[n] = '\0';
    fprintf(stderr, "%s\n", buf);
    free(buf);
}

/* ------------------------------------------------------------------ */
/* Interceptors                                                        */
/* ------------------------------------------------------------------ */

void glCompileShader(GLuint shader)
{
    log_gl_context();
    init_gl_funcs();

    GLuint tid = next_id();
    fprintf(stderr, "[shader-trace] === BEGIN SHADER %u (shader id %u) ===\n", tid, shader);

    /* Call original first (RTLD_NEXT), then dump diagnostics. */
    if (!p_glCompileShader)
        return;
    ((void (*)(GLuint))p_glCompileShader)(shader);

    GLint status = query_shader_iv(shader, GL_COMPILE_STATUS);
    GLint type = query_shader_iv(shader, GL_SHADER_TYPE);
    GLint ilen = query_shader_iv(shader, GL_INFO_LOG_LENGTH);

    fprintf(stderr, "[shader-trace] shader %u: compile_status=%d type=%s info_log_length=%d\n",
            shader, status, shader_type_str(type), ilen);

    dump_shader_source(shader);

    /* Print info log even on success. */
    dump_info_log("info log",
                  (void (*)(GLuint, GLsizei, GLsizei *, GLchar *))p_glGetShaderInfoLog,
                  shader, ilen);

    fprintf(stderr, "[shader-trace] === END SHADER %u (shader id %u) ===\n", tid, shader);
}

void glLinkProgram(GLuint program)
{
    log_gl_context();
    init_gl_funcs();

    GLuint tid = next_id();
    fprintf(stderr, "[shader-trace] === BEGIN LINK %u (program id %u) ===\n", tid, program);

    if (!p_glLinkProgram)
        return;
    ((void (*)(GLuint))p_glLinkProgram)(program);

    GLint status = query_program_iv(program, GL_LINK_STATUS);
    GLint ilen = query_program_iv(program, GL_INFO_LOG_LENGTH);

    fprintf(stderr, "[shader-trace] program %u: link_status=%d info_log_length=%d\n",
            program, status, ilen);

    dump_info_log("link info log",
                  (void (*)(GLuint, GLsizei, GLsizei *, GLchar *))p_glGetProgramInfoLog,
                  program, ilen);

    fprintf(stderr, "[shader-trace] === END LINK %u (program id %u) ===\n", tid, program);
}