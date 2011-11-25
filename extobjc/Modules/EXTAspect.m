//
//  EXTAspect.m
//  extobjc
//
//  Created by Justin Spahr-Summers on 24.11.11.
//  Released into the public domain.
//

#import "EXTAspect.h"
#import "EXTRuntimeExtensions.h"
#import "ffi.h"
#import <objc/runtime.h>

typedef void (^ext_adviceOriginalMethodBlock)(void);
typedef void (*ext_adviceIMP)(id, SEL, ext_adviceOriginalMethodBlock);

static SEL originalSelectorForSelector (SEL selector) {
    NSString *methodName = NSStringFromSelector(selector);
    NSString *originalMethodName = [methodName stringByAppendingString:@"_unadvised_"];
    return NSSelectorFromString(originalMethodName);
}

static void methodReplacementWithAdvice (ffi_cif *cif, void *result, void **args, void *userdata) {
    id self = *(__strong id *)args[0];
    SEL _cmd = *(SEL *)args[1];

    Class aspectContainer = (__bridge Class)userdata;
    Class selfClass = object_getClass(self);

    if (class_isMetaClass(selfClass)) {
        // if we're adding advice to a class method, use class methods on the
        // aspect container as well
        aspectContainer = object_getClass(aspectContainer);
    }

    ext_adviceOriginalMethodBlock originalMethod = ^{
        SEL originalSelector = originalSelectorForSelector(_cmd);
        IMP originalIMP = class_getMethodImplementation(selfClass, originalSelector);

        ffi_call(cif, FFI_FN(originalIMP), result, args);
    };

    Method advice = class_getInstanceMethod(aspectContainer, @selector(advise:));
    if (advice) {
        ext_adviceIMP adviceIMP = (ext_adviceIMP)method_getImplementation(advice);
        adviceIMP(self, _cmd, originalMethod);
    } else {
        originalMethod();
    }
}

static void ext_injectAspect (Class containerClass, Class class) {
    unsigned imethodCount = 0;
    Method *imethodList = class_copyMethodList(class, &imethodCount);

    for (unsigned i = 0;i < imethodCount;++i) {
        /*
         * All memory allocations below _intentionally_ leak memory. These
         * structures need to stick around for as long as the FFI closure will
         * be used, and, since we're installing a new method on a class, we're
         * operating under the assumption that it could be used anytime during
         * the lifetime of the application. There would be no appropriate time
         * to free this memory.
         */

        Method method = imethodList[i];
        SEL selector = method_getName(method);

        ffi_type *returnType = &ffi_type_sint;
        
        // argument types for testing
        unsigned argumentCount = 3;
        ffi_type **argTypes = malloc(sizeof(*argTypes) * argumentCount);
        if (!argTypes) {
            fprintf(stderr, "ERROR: Could not allocate space for %u arguments\n", argumentCount);
            continue;
        }

        argTypes[0] = &ffi_type_pointer;
        argTypes[1] = &ffi_type_pointer;
        argTypes[2] = &ffi_type_sint;

        ffi_cif *methodCIF = malloc(sizeof(*methodCIF));
        if (!methodCIF) {
            fprintf(stderr, "ERROR: Could not allocate new FFI CIF\n");
            break;
        }

        ffi_prep_cif(methodCIF, FFI_DEFAULT_ABI, argumentCount, returnType, argTypes);

        SEL movedSelector = originalSelectorForSelector(selector);
        class_addMethod(class, movedSelector, method_getImplementation(method), method_getTypeEncoding(method));

        void *replacementIMP = NULL;
        ffi_closure *closure = ffi_closure_alloc(sizeof(ffi_closure), &replacementIMP);

        ffi_prep_closure_loc(closure, methodCIF, &methodReplacementWithAdvice, (__bridge void *)containerClass, replacementIMP);
        method_setImplementation(method, (IMP)replacementIMP);
    }

    free(imethodList);
}

BOOL ext_addAspect (Protocol *protocol, Class methodContainer) {
    return ext_loadSpecialProtocol(protocol, ^(Class destinationClass){
        ext_injectAspect(methodContainer, destinationClass);
    });
}

void ext_loadAspect (Protocol *protocol) {
    ext_specialProtocolReadyForInjection(protocol);
}
