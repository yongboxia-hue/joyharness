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
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute, kCFBooleanTrue);
    usleep(250000);

    const char *names[] = {"sidebar-connection", "sidebar-mapping", "sidebar-permissions", "sidebar-about"};
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
        usleep(300000);
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
    usleep(350000);

    CFStringRef cardIdentifier = CFSTR("mapping-card-right-ZR");
    AXUIElementRef card = find_identifier(app, cardIdentifier);
    CGRect cardFrame;
    if (!card || !copy_frame(card, &cardFrame) || cardFrame.size.width < 220 || cardFrame.size.height < 80) {
        fprintf(stderr, "Missing or undersized mapping card hit target\n");
        if (card) CFRelease(card);
        CFRelease(app);
        return 1;
    }
    click_point(CGPointMake(CGRectGetMaxX(cardFrame) - 6, CGRectGetMidY(cardFrame)));
    CFRelease(card);
    usleep(500000);
    AXUIElementRef editor = find_identifier(app, CFSTR("mapping-editor"));
    if (!editor) {
        fprintf(stderr, "Mapping card blank edge did not open the inline editor\n");
        CFRelease(app);
        return 1;
    }
    CFRelease(editor);
    printf("mapping-card-right-ZR %.0fx%.0f passed\n", cardFrame.size.width, cardFrame.size.height);
    CFRelease(app);
    puts("Native hit-target verification passed.");
    return 0;
}
