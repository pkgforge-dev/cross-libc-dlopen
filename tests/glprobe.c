/* glprobe.c -- the OpenGL analogue of vkprobe.
 *
 * Two questions, and the second is the one that is easy to get wrong.
 *
 *   1. Is there a working GL on this host at all?  Open a display, choose a
 *      visual, make a context current, read GL_RENDERER.
 *
 *   2. Does the process have ALL of libGL, or only the part somebody wrote out
 *      by hand?  A forwarding shim that exports a subset fails in two different
 *      ways and only one of them is loud: a name it does not export at all is
 *      `undefined symbol` at load, which is obvious, while a name it exports
 *      but cannot forward returns zero and the frame simply comes out wrong.
 *      So this probe CLEARS TO A KNOWN COLOUR AND READS THE PIXEL BACK. A
 *      forwarded glClearColor puts 0x40 0x80 0xc0 in the buffer; a stub that
 *      returns zero leaves black, and the two are distinguishable.
 *
 * The calls used past the visual are deliberately outside the set glxgears
 * links -- glClearColor, glGetIntegerv, glPixelStorei, glReadPixels, the
 * texture-object family -- because a shim written to make glxgears run is
 * exactly the shim that passes a glxgears-shaped test and nothing else.
 *
 * Exit 0 on success, 1 on a failure that names itself. Needs an X display;
 * xvfb-run -s '-screen 0 1024x768x24 +extension GLX +render' is enough.
 */

#include <GL/gl.h>
#include <GL/glx.h>
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
	/* stdout is block-buffered into a pipe, and a probe that crashes then
	 * loses every line it printed. */
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);

	Display *dpy = XOpenDisplay(NULL);
	if (!dpy) {
		printf("FAILED: no X display (set DISPLAY, or run under xvfb-run)\n");
		return 1;
	}

	int attrs[] = { GLX_RGBA, GLX_DOUBLEBUFFER, GLX_DEPTH_SIZE, 1,
	                GLX_RED_SIZE, 1, GLX_GREEN_SIZE, 1, GLX_BLUE_SIZE, 1, None };
	XVisualInfo *vi = glXChooseVisual(dpy, DefaultScreen(dpy), attrs);
	if (!vi) {
		/* This is the message the whole gl-fwd shim exists to remove. It says
		 * "visual", it means "there is no GL driver this process can reach". */
		printf("FAILED: no RGB double-buffered visual\n");
		return 1;
	}

	Window root = RootWindow(dpy, vi->screen);
	XSetWindowAttributes swa;
	memset(&swa, 0, sizeof swa);
	swa.colormap = XCreateColormap(dpy, root, vi->visual, AllocNone);
	swa.event_mask = StructureNotifyMask;
	Window win = XCreateWindow(dpy, root, 0, 0, 64, 64, 0, vi->depth, InputOutput,
	                           vi->visual, CWColormap | CWEventMask, &swa);
	XMapWindow(dpy, win);

	GLXContext ctx = glXCreateContext(dpy, vi, NULL, True);
	if (!ctx) {
		printf("FAILED: glXCreateContext returned NULL\n");
		return 1;
	}
	if (!glXMakeCurrent(dpy, win, ctx)) {
		printf("FAILED: glXMakeCurrent\n");
		return 1;
	}

	const GLubyte *rend = glGetString(GL_RENDERER);
	const GLubyte *vers = glGetString(GL_VERSION);
	printf("  GL_RENDERER               : %s\n", rend ? (const char *)rend : "(null)");
	printf("  GL_VERSION                : %s\n", vers ? (const char *)vers : "(null)");
	if (!rend) {
		printf("FAILED: glGetString(GL_RENDERER) returned NULL\n");
		return 1;
	}

	/* ---- past the glxgears set, and measured rather than assumed ---- */
	GLint vp[4] = { -1, -1, -1, -1 };
	glGetIntegerv(GL_VIEWPORT, vp);
	printf("  glGetIntegerv(GL_VIEWPORT): %d %d %d %d\n", vp[0], vp[1], vp[2], vp[3]);
	if (vp[2] <= 0 || vp[3] <= 0) {
		printf("FAILED: glGetIntegerv wrote no viewport -- the call did not "
		       "reach a driver (a stub that returns zero looks exactly like "
		       "this)\n");
		return 1;
	}

	GLuint tex = 0;
	glGenTextures(1, &tex);
	if (tex == 0) {
		printf("FAILED: glGenTextures produced no name\n");
		return 1;
	}
	glBindTexture(GL_TEXTURE_2D, tex);
	glDeleteTextures(1, &tex);

	glClearColor(0.25f, 0.5f, 0.75f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	glFinish();

	unsigned char px[4] = { 0, 0, 0, 0 };
	glPixelStorei(GL_PACK_ALIGNMENT, 1);
	glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	printf("  readback rgba             : %u %u %u %u (want ~64 128 191 255)\n",
	       px[0], px[1], px[2], px[3]);

	/* +-2 for whatever the framebuffer's precision does to 0.25/0.5/0.75. */
	int ok = px[0] > 60 && px[0] < 70 && px[1] > 124 && px[1] < 134 &&
	         px[2] > 186 && px[2] < 196;
	if (!ok) {
		printf("FAILED: the pixel does not carry the colour that was set. "
		       "glClearColor was exported but did not reach the driver.\n");
		return 1;
	}

	GLenum err = glGetError();
	printf("  glGetError                : 0x%x\n", (unsigned)err);

	glXMakeCurrent(dpy, None, NULL);
	glXDestroyContext(dpy, ctx);
	XCloseDisplay(dpy);
	printf("OK: GL is complete -- context, state query, texture names and a "
	       "colour that survived the round trip\n");
	return 0;
}
