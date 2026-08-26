/* eglprobe.c: glprobe's question, asked of EGL, with no window system.
 *
 * eglgears runs forever and prints through a block-buffered stdout, so a
 * timeout kills it and takes every line it printed with it: "Terminated" and
 * nothing else is the same output whether it rendered perfectly or never
 * started. This probe answers in one line and exits.
 *
 * EGL_PLATFORM=surfaceless removes X from the question entirely, which matters
 * because the failure being measured is about a missing VENDOR library, not a
 * missing display, and a display error would be indistinguishable.
 *
 * Exit 0 on success, 1 on a failure that names itself.
 */

#include <EGL/egl.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>

static const char *egl_err(EGLint e) {
	switch (e) {
	case EGL_SUCCESS:             return "EGL_SUCCESS";
	case EGL_NOT_INITIALIZED:     return "EGL_NOT_INITIALIZED";
	case EGL_BAD_ACCESS:          return "EGL_BAD_ACCESS";
	case EGL_BAD_ALLOC:           return "EGL_BAD_ALLOC";
	case EGL_BAD_ATTRIBUTE:       return "EGL_BAD_ATTRIBUTE";
	case EGL_BAD_CONFIG:          return "EGL_BAD_CONFIG";
	case EGL_BAD_CONTEXT:         return "EGL_BAD_CONTEXT";
	case EGL_BAD_DISPLAY:         return "EGL_BAD_DISPLAY";
	case EGL_BAD_MATCH:           return "EGL_BAD_MATCH";
	case EGL_BAD_PARAMETER:       return "EGL_BAD_PARAMETER";
	case EGL_BAD_SURFACE:         return "EGL_BAD_SURFACE";
	default:                      return "EGL_<other>";
	}
}

int main(void) {
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);

	EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	if (dpy == EGL_NO_DISPLAY) {
		printf("FAILED: eglGetDisplay -> EGL_NO_DISPLAY (%s)\n",
		       egl_err(eglGetError()));
		return 1;
	}
	EGLint major = 0, minor = 0;
	if (!eglInitialize(dpy, &major, &minor)) {
		/* This is the EGL shape of "the bundled dispatcher found no vendor". */
		printf("FAILED: eglInitialize -> %s\n", egl_err(eglGetError()));
		return 1;
	}
	printf("  EGL_VERSION               : %d.%d\n", major, minor);
	printf("  EGL_VENDOR                : %s\n", eglQueryString(dpy, EGL_VENDOR));

	if (!eglBindAPI(EGL_OPENGL_API)) {
		printf("FAILED: eglBindAPI(EGL_OPENGL_API) -> %s\n", egl_err(eglGetError()));
		return 1;
	}

	EGLint cfg_attrs[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
	                       EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
	                       EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
	                       EGL_NONE };
	EGLConfig cfg;
	EGLint n = 0;
	if (!eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &n) || n < 1) {
		printf("FAILED: eglChooseConfig found no config (%s)\n",
		       egl_err(eglGetError()));
		return 1;
	}

	EGLint surf_attrs[] = { EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_NONE };
	EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, surf_attrs);
	EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, NULL);
	if (ctx == EGL_NO_CONTEXT) {
		printf("FAILED: eglCreateContext -> %s\n", egl_err(eglGetError()));
		return 1;
	}
	if (!eglMakeCurrent(dpy, surf, surf, ctx)) {
		printf("FAILED: eglMakeCurrent -> %s\n", egl_err(eglGetError()));
		return 1;
	}

	const GLubyte *rend = glGetString(GL_RENDERER);
	printf("  GL_RENDERER               : %s\n", rend ? (const char *)rend : "(null)");
	if (!rend) {
		printf("FAILED: a current EGL context, and still no renderer string\n");
		return 1;
	}

	/* Same round trip as glprobe: a stub that returns zero and a driver that
	 * actually cleared the buffer are otherwise identical from out here. */
	unsigned char px[4] = { 0, 0, 0, 0 };
	glClearColor(0.25f, 0.5f, 0.75f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glFinish();
	glPixelStorei(GL_PACK_ALIGNMENT, 1);
	glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	printf("  readback rgba             : %u %u %u %u (want ~64 128 191 255)\n",
	       px[0], px[1], px[2], px[3]);
	if (!(px[0] > 60 && px[0] < 70 && px[1] > 124 && px[1] < 134 &&
	      px[2] > 186 && px[2] < 196)) {
		printf("FAILED: the pixel does not carry the colour that was set\n");
		return 1;
	}

	eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglTerminate(dpy);
	printf("OK: EGL is complete -- display, context and a colour that survived "
	       "the round trip\n");
	return 0;
}
