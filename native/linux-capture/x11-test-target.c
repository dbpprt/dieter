#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <X11/Xlib.h>

int main(void) {
    Display *display = XOpenDisplay(NULL);
    if (display == NULL) {
        fputs("open X display failed\n", stderr);
        return 1;
    }
    int screen = DefaultScreen(display);
    Window root = RootWindow(display, screen);
    Window window = XCreateSimpleWindow(display, root, 0, 0,
        (unsigned int)DisplayWidth(display, screen), (unsigned int)DisplayHeight(display, screen),
        0, BlackPixel(display, screen), 0x204060);
    XSelectInput(display, window, ExposureMask | PointerMotionMask | ButtonPressMask |
        ButtonReleaseMask | KeyPressMask | KeyReleaseMask);
    XMapRaised(display, window);
    XSetInputFocus(display, window, RevertToParent, CurrentTime);
    XFlush(display);
    puts("READY");
    fflush(stdout);

    int motion = 0, button_down = 0, button_up = 0, key_down = 0, key_up = 0;
    struct pollfd descriptor = {.fd = ConnectionNumber(display), .events = POLLIN};
    for (int remaining = 100; remaining > 0; remaining--) {
        int ready = poll(&descriptor, 1, 100);
        if (ready < 0) break;
        while (XPending(display) > 0) {
            XEvent event;
            XNextEvent(display, &event);
            if (event.type == MotionNotify) motion = 1;
            if (event.type == ButtonPress && event.xbutton.button == 1) button_down = 1;
            if (event.type == ButtonRelease && event.xbutton.button == 1) button_up = 1;
            if (event.type == KeyPress && event.xkey.keycode == 38) key_down = 1;
            if (event.type == KeyRelease && event.xkey.keycode == 38) key_up = 1;
        }
        if (motion && button_down && button_up && key_down && key_up) {
            puts("PASS");
            XDestroyWindow(display, window);
            XCloseDisplay(display);
            return 0;
        }
    }
    fprintf(stderr, "missing events: motion=%d button=%d/%d key=%d/%d\n",
        motion, button_down, button_up, key_down, key_up);
    XDestroyWindow(display, window);
    XCloseDisplay(display);
    return 1;
}
