/*
 * shader_probe.c — compile SceneFX/labwc GLSL through the *target* GLES driver
 * and print the driver's own info log (which SceneFX discards).  Built natively
 * on O6N against the CIX libmali vendor EGL/GLES stack.
 *
 * usage: shader_probe <manifest>
 *   manifest lines:  <label>\t<vert-file>\t<frag-file>
 *   a missing/empty file path is skipped for that stage.
 *
 * exit: 0 all programs compiled+linked; 1 any failure; 2 setup failure.
 *
 * The EGL bootstrap mirrors wlroots' wlr_egl_create_with_drm_fd(): a GBM
 * platform display on a DRM *render* node (so no DRM master is taken), then a
 * surfaceless ES2 context.  Falls back to EGL_DEFAULT_DISPLAY / surfaceless if
 * the blob rejects the GBM platform.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

/* libgbm's header is not installed on O6N; only two symbols are needed. */
extern void *gbm_create_device(int fd);
extern void gbm_device_destroy(void *gbm);

/* Kept alive for the whole process: the EGL display created from the GBM device
 * outlives try_gbm(), so both must be released only after eglTerminate(). */
static void *g_gbm = NULL;
static int g_drm_fd = -1;

static char *read_file(const char *path) {
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
	long n = ftell(f);
	if (n < 0) { fclose(f); return NULL; }
	rewind(f);
	char *buf = malloc((size_t)n + 1);
	if (!buf) { fclose(f); return NULL; }
	size_t got = fread(buf, 1, (size_t)n, f);
	buf[got] = '\0';
	fclose(f);
	return buf;
}

static void dump_gl_info(void) {
	const char *v = (const char *)glGetString(GL_VERSION);
	const char *r = (const char *)glGetString(GL_RENDERER);
	const char *ven = (const char *)glGetString(GL_VENDOR);
	const char *s = (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION);
	const char *e = (const char *)glGetString(GL_EXTENSIONS);
	printf("[driver] GL_VERSION                = %s\n", v ? v : "(null)");
	printf("[driver] GL_RENDERER               = %s\n", r ? r : "(null)");
	printf("[driver] GL_VENDOR                 = %s\n", ven ? ven : "(null)");
	printf("[driver] GL_SHADING_LANGUAGE_VER   = %s\n", s ? s : "(null)");
	printf("[driver] GL_EXTENSIONS             = %s\n", e ? e : "(null)");
}

static EGLDisplay try_gbm(void) {
	PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
		(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
	int fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
	if (fd < 0) { fprintf(stderr, "[egl] open renderD128: %s\n", strerror(errno)); return EGL_NO_DISPLAY; }
	void *gbm = gbm_create_device(fd);
	if (!gbm) { fprintf(stderr, "[egl] gbm_create_device failed\n"); close(fd); return EGL_NO_DISPLAY; }
	EGLDisplay dpy = EGL_NO_DISPLAY;
	if (getPlatformDisplay) {
		dpy = getPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
	}
	if (dpy != EGL_NO_DISPLAY) {
		printf("[egl] using EGL_PLATFORM_GBM_KHR on renderD128\n");
		g_gbm = gbm;
		g_drm_fd = fd;
		return dpy;
	}
	gbm_device_destroy(gbm);
	close(fd);
	return EGL_NO_DISPLAY;
}

static GLuint compile_stage(GLenum type, const char *src, const char *label) {
	GLuint sh = glCreateShader(type);
	glShaderSource(sh, 1, &src, NULL);
	glCompileShader(sh);
	GLint ok = GL_FALSE;
	glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
	char log[8192];
	GLsizei len = 0;
	log[0] = '\0';
	glGetShaderInfoLog(sh, sizeof(log) - 1, &len, log);
	printf("  %-8s %-5s\n", label, ok == GL_TRUE ? "OK" : "FAIL");
	if (len > 0) {
		/* indent every line of the driver log for readability */
		printf("    | ");
		for (GLsizei i = 0; i < len; i++) {
			putchar(log[i]);
			if (log[i] == '\n' && i + 1 < len) printf("    | ");
		}
		if (len > 0 && log[len - 1] != '\n') putchar('\n');
	}
	if (ok != GL_TRUE) { glDeleteShader(sh); return 0; }
	return sh;
}

int main(int argc, char **argv) {
	if (argc != 2) { fprintf(stderr, "usage: %s <manifest>\n", argv[0]); return 2; }

	EGLDisplay dpy = try_gbm();
	if (dpy == EGL_NO_DISPLAY) {
		dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
		printf("[egl] falling back to EGL_DEFAULT_DISPLAY\n");
	}
	if (dpy == EGL_NO_DISPLAY) { fprintf(stderr, "[egl] no display\n"); return 2; }

	EGLint major, minor;
	if (!eglInitialize(dpy, &major, &minor)) {
		fprintf(stderr, "[egl] eglInitialize failed: 0x%x\n", eglGetError());
		return 2;
	}
	printf("[egl] EGL %d.%d\n", major, minor);
	const char *egl_vendor = eglQueryString(dpy, EGL_VENDOR);
	const char *egl_version = eglQueryString(dpy, EGL_VERSION);
	printf("[egl] EGL_VENDOR   = %s\n", egl_vendor ? egl_vendor : "(null)");
	printf("[egl] EGL_VERSION  = %s\n", egl_version ? egl_version : "(null)");
	eglBindAPI(EGL_OPENGL_ES_API);
	EGLint cfg_attr[] = {
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
		EGL_NONE
	};
	EGLConfig cfg;
	EGLint ncfg = 0;
	if (!eglChooseConfig(dpy, cfg_attr, &cfg, 1, &ncfg) || ncfg < 1) {
		/* blob may refuse configs without a surface type; try minimal */
		EGLint cfg2[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE };
		if (!eglChooseConfig(dpy, cfg2, &cfg, 1, &ncfg) || ncfg < 1) {
			fprintf(stderr, "[egl] eglChooseConfig failed: 0x%x\n", eglGetError());
			return 2;
		}
	}
	EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attr);
	if (ctx == EGL_NO_CONTEXT) {
		fprintf(stderr, "[egl] eglCreateContext failed: 0x%x\n", eglGetError());
		return 2;
	}
	if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
		fprintf(stderr, "[egl] eglMakeCurrent failed: 0x%x\n", eglGetError());
		return 2;
	}
	printf("[egl] context current (surfaceless ES2)\n\n");
	dump_gl_info();
	printf("\n");

	FILE *m = fopen(argv[1], "r");
	if (!m) { perror(argv[1]); return 2; }
	char line[4096];
	int fails = 0, total = 0;
	while (fgets(line, sizeof(line), m)) {
		char *nl = strchr(line, '\n'); if (nl) *nl = '\0';
		if (line[0] == '\0' || line[0] == '#') continue;
		char *tab1 = strchr(line, '\t'); if (!tab1) continue; *tab1 = '\0';
		char *tab2 = strchr(tab1 + 1, '\t'); if (!tab2) continue; *tab2 = '\0';
		const char *label = line;
		const char *vpath = tab1 + 1;
		const char *fpath = tab2 + 1;

		total++;
		printf("=== %s ===\n", label);
		char *vsrc = (vpath[0] && strcmp(vpath, "-") != 0) ? read_file(vpath) : NULL;
		char *fsrc = (fpath[0] && strcmp(fpath, "-") != 0) ? read_file(fpath) : NULL;
		if ((vpath[0] && strcmp(vpath, "-") != 0 && !vsrc) ||
		    (fpath[0] && strcmp(fpath, "-") != 0 && !fsrc)) {
			printf("  file read failed (v=%s f=%s)\n", vpath, fpath);
			fails++; free(vsrc); free(fsrc); continue;
		}
		GLuint vsh = vsrc ? compile_stage(GL_VERTEX_SHADER, vsrc, "VERT") : 0;
		GLuint fsh = fsrc ? compile_stage(GL_FRAGMENT_SHADER, fsrc, "FRAG") : 0;
		if (vsrc && !vsh) fails++;
		if (fsrc && !fsh) fails++;
		if (vsh && fsh) {
			GLuint prog = glCreateProgram();
			glAttachShader(prog, vsh);
			glAttachShader(prog, fsh);
			glLinkProgram(prog);
			GLint ok = GL_FALSE;
			glGetProgramiv(prog, GL_LINK_STATUS, &ok);
			char log[8192]; GLsizei len = 0; log[0] = '\0';
			glGetProgramInfoLog(prog, sizeof(log) - 1, &len, log);
			printf("  %-8s %-5s\n", "LINK", ok == GL_TRUE ? "OK" : "FAIL");
			if (len > 0) {
				printf("    | ");
				for (GLsizei i = 0; i < len; i++) {
					putchar(log[i]);
					if (log[i] == '\n' && i + 1 < len) printf("    | ");
				}
				if (len && log[len - 1] != '\n') putchar('\n');
			}
			if (ok != GL_TRUE) fails++;
			glDeleteProgram(prog);
		}
		if (vsh) glDeleteShader(vsh);
		if (fsh) glDeleteShader(fsh);
		free(vsrc); free(fsrc);
	}
	fclose(m);
	printf("\n[summary] programs=%d failures=%d\n", total, fails);
	eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(dpy, ctx);
	eglTerminate(dpy);
	/* release the GBM platform resources after EGL is done with them */
	if (g_gbm) {
		gbm_device_destroy(g_gbm);
		g_gbm = NULL;
	}
	if (g_drm_fd >= 0) {
		close(g_drm_fd);
		g_drm_fd = -1;
	}
	return fails ? 1 : 0;
}
