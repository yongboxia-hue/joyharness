#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static AXUIElementRef find_identifier(AXUIElementRef element, CFStringRef wanted) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, CFSTR("AXIdentifier"), &value) == kAXErrorSuccess && value) {
        bool matches = CFGetTypeID(value) == CFStringGetTypeID() && CFStringCompare(value, wanted, 0) == kCFCompareEqualTo;
        CFRelease(value);
        if (matches) return CFRetain(element);
    }

    CFTypeRef childrenValue = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &childrenValue) != kAXErrorSuccess || !childrenValue) return NULL;
    AXUIElementRef found = NULL;
    if (CFGetTypeID(childrenValue) == CFArrayGetTypeID()) {
        CFArrayRef children = childrenValue;
        for (CFIndex index = 0; index < CFArrayGetCount(children) && !found; index++) {
            found = find_identifier((AXUIElementRef)CFArrayGetValueAtIndex(children, index), wanted);
        }
    }
    CFRelease(childrenValue);
    return found;
}

static bool copy_frame(AXUIElementRef element, CGRect *frame) {
    CFTypeRef positionValue = NULL;
    CFTypeRef sizeValue = NULL;
    CGPoint position;
    CGSize size;
    bool ok = AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &positionValue) == kAXErrorSuccess
        && AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess
        && positionValue && sizeValue
        && AXValueGetValue(positionValue, kAXValueCGPointType, &position)
        && AXValueGetValue(sizeValue, kAXValueCGSizeType, &size);
    if (positionValue) CFRelease(positionValue);
    if (sizeValue) CFRelease(sizeValue);
    if (ok) *frame = (CGRect){position, size};
    return ok;
}

static bool is_selected(AXUIElementRef element) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXValueAttribute, &value) != kAXErrorSuccess || !value) return false;
    bool selected = CFGetTypeID(value) == CFStringGetTypeID()
        && CFStringCompare(value, CFSTR("已选择"), 0) == kCFCompareEqualTo;
    CFRelease(value);
    return selected;
}

static void click_point(CGPoint point) {
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <pid>\n", argv[0]);
        return 2;
    }
    pid_t pid = (pid_t)strtol(argv[1], NULL, 10);
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    // Activation is not instant, and a synthetic click that arrives before the
    // window is key is spent bringing the app forward instead of landing on
    // what it was aimed at -- which made this check pass or fail by timing.
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute, kCFBooleanTrue);
    usleep(1200000);

    // Close anything modal before touching the sidebar. A sheet left open by
    // an earlier run -- or by a person -- swallows every click behind it, and
    // the failure that produces ("the sidebar did not respond") points at the
    // wrong thing entirely.
    AXUIElementRef leftover = find_identifier(app, CFSTR("mapping-editor-cancel"));
    if (leftover) {
        AXUIElementPerformAction(leftover, kAXPressAction);
        CFRelease(leftover);
        usleep(500000);
    }

    // Park the window at a known spot first. The window is 1180 points wide,
    // so wherever the user last dragged it the right-hand column of cards can
    // hang off the side of the display -- and a synthetic click posted to a
    // coordinate that is not on any screen simply goes nowhere. The sidebar
    // clicks on the left kept landing, so the check looked like a failure of
    // the card rather than of where the window happened to be.
    CFTypeRef windowsValue = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windowsValue) == kAXErrorSuccess
        && windowsValue && CFGetTypeID(windowsValue) == CFArrayGetTypeID()
        && CFArrayGetCount((CFArrayRef)windowsValue) > 0) {
        AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex((CFArrayRef)windowsValue, 0);
        CGPoint origin = CGPointMake(20, 40);
        AXValueRef originValue = AXValueCreate(kAXValueCGPointType, &origin);
        AXUIElementSetAttributeValue(window, kAXPositionAttribute, originValue);
        CFRelease(originValue);
        usleep(400000);
    }
    if (windowsValue) CFRelease(windowsValue);

    // There is no 权限 page: authorization moved into 关于, and the UI contract
    // asserts PermissionsView stays deleted. This list kept asking for its
    // sidebar row anyway, so the check failed on the one thing that was
    // working as designed and never got as far as the cards below it.
    const char *names[] = {"sidebar-connection", "sidebar-mapping", "sidebar-settings", "sidebar-about"};
    for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
        CFStringRef identifier = CFStringCreateWithCString(NULL, names[index], kCFStringEncodingUTF8);
        AXUIElementRef button = find_identifier(app, identifier);
        if (!button) {
            fprintf(stderr, "Missing accessibility element: %s\n", names[index]);
            CFRelease(identifier);
            CFRelease(app);
            return 1;
        }
        CGRect frame;
        if (!copy_frame(button, &frame) || frame.size.width < 200 || frame.size.height < 38) {
            fprintf(stderr, "Undersized hit target: %s\n", names[index]);
            CFRelease(button);
            CFRelease(identifier);
            CFRelease(app);
            return 1;
        }
        click_point(CGPointMake(CGRectGetMaxX(frame) - 6, CGRectGetMidY(frame)));
        CFRelease(button);
        usleep(700000);
        button = find_identifier(app, identifier);
        if (!button || !is_selected(button)) {
            fprintf(stderr, "Blank right edge did not activate: %s\n", names[index]);
            if (button) CFRelease(button);
            CFRelease(identifier);
            CFRelease(app);
            return 1;
        }
        printf("%s %.0fx%.0f passed\n", names[index], frame.size.width, frame.size.height);
        CFRelease(button);
        CFRelease(identifier);
    }

    CFStringRef mappingIdentifier = CFSTR("sidebar-mapping");
    AXUIElementRef mappingButton = find_identifier(app, mappingIdentifier);
    if (!mappingButton) {
        fprintf(stderr, "Missing mapping sidebar button\n");
        CFRelease(app);
        return 1;
    }
    AXUIElementPerformAction(mappingButton, kAXPressAction);
    CFRelease(mappingButton);
    // The board lays itself out against the window, and the cards settle into
    // their columns after the page change. Measuring too early gave a frame
    // the card no longer occupied by the time the click arrived.
    usleep(1200000);

    CFStringRef cardIdentifier = CFSTR("mapping-card-right-ZR");
    AXUIElementRef card = find_identifier(app, cardIdentifier);
    CGRect cardFrame;
    // 220x80 described a card from before the board sized each one to what it
    // holds: a single-action button is 190x48 now, and a box sized for two
    // rows was exactly the thing that made half the board look unfinished.
    // What this is really guarding is that the whole card is clickable rather
    // than just the text inside it, so the floor is a comfortable target --
    // well above the 28pt macOS asks for -- not the old layout's dimensions.
    if (!card || !copy_frame(card, &cardFrame) || cardFrame.size.width < 180 || cardFrame.size.height < 44) {
        fprintf(stderr, "Missing or undersized mapping card hit target\n");
        if (card) CFRelease(card);
        CFRelease(app);
        return 1;
    }
    click_point(CGPointMake(CGRectGetMaxX(cardFrame) - 6, CGRectGetMidY(cardFrame)));
    CFRelease(card);
    usleep(1000000);
    AXUIElementRef editor = find_identifier(app, CFSTR("mapping-editor-save"));
    if (!editor) {
        fprintf(stderr, "Mapping card blank edge did not open the inline editor\n");
        CFRelease(app);
        return 1;
    }
    CFRelease(editor);

    // Put the app back the way it was found. The editor is a modal sheet, and
    // a sheet left open blocks every click behind it -- so this check used to
    // pass once and then fail on its own leftovers the next time it ran.
    AXUIElementRef cancel = find_identifier(app, CFSTR("mapping-editor-cancel"));
    if (cancel) {
        AXUIElementPerformAction(cancel, kAXPressAction);
        CFRelease(cancel);
        usleep(400000);
    }
    printf("mapping-card-right-ZR %.0fx%.0f passed\n", cardFrame.size.width, cardFrame.size.height);
    CFRelease(app);
    puts("Native hit-target verification passed.");
    return 0;
}
