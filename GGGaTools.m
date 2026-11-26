#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>
#include <dlfcn.h>
#include <string.h>

// A diagnostic build: no message contents or recipient identifiers are logged.
static NSString *const GGGaDirectText = @"【GGGaTools测试】这是一条插件直接发送的测试消息";
static atomic_int GGGaNativeSendCount;
static atomic_int GGGaListenerSendHits;
static atomic_int GGGaBlockSendHits;
static atomic_int GGGaSendWrongType;
static atomic_int GGGaSendMissingSession;
static atomic_int GGGaSendMissingReceivers;
static atomic_int GGGaSendOtherContent;
static atomic_int GGGaIncomingHits;
static atomic_int GGGaIncomingOtherType;
static atomic_int GGGaIncomingOwn;
static atomic_int GGGaIncomingNoText;
static atomic_int GGGaIncomingTextHits;
static BOOL GGGaSendHookInstalled;
static BOOL GGGaBlockSendHookInstalled;
static BOOL GGGaIncomingHookInstalled;
static char GGGaInternalRequestKey;
static id GGGaTextTemplate;
static id GGGaImageTemplate;
static id GGGaTextService;
static id GGGaImageService;
static BOOL GGGaTextUsesBlock;
static BOOL GGGaImageUsesBlock;
static NSString *GGGaLatestAppCid;
static NSDate *GGGaLastCalibrationAt;
static NSString *GGGaLastIncomingText;
static void (*GGGaOriginalSend)(id, SEL, id, id, id);
static void (*GGGaOriginalBlockSend)(id, SEL, id, id, id, id, id);
static void (*GGGaOriginalOnMessage)(id, SEL, id);

// Each probe forwards the original arguments and records only a call count.
typedef struct {
    const char *className;
    const char *selectorName;
    const char *encoding;
    atomic_uint hits;
    unsigned baseline;
    IMP original;
} GGGaCountProbe;

static GGGaCountProbe GGGaBridgeDispatch = {"FlutterServiceCallDispather", "dispatch:result:", "v32@0:8@16@?24"};
static GGGaCountProbe GGGaBridgeSend = {"FlutterMessageClient", "send:result:", "v32@0:8@16@?24"};
static GGGaCountProbe GGGaAlternateReceive = {"AIMManager", "onReceived:entend:", "v32@0:8@16@24"};
static GGGaCountProbe GGGaLocalHistory = {"AIMPubMsgService", "listPreviousLocalMsgs:cursor:count:listener:", "v44@0:8@16q24i32@36"};
static GGGaCountProbe GGGaRemoteHistory = {"AIMPubMsgService", "listPreviousMsgs:cursor:count:listener:", "v44@0:8@16q24i32@36"};
static GGGaCountProbe GGGaLocalHistoryBlock = {"AIMPubMsgService", "listPreviousLocalMsgsWithBlock:cursor:count:onSuccess:onFailure:", "v52@0:8@16q24i32@?36@?44"};
static GGGaCountProbe GGGaRemoteHistoryBlock = {"AIMPubMsgService", "listPreviousMsgsWithBlock:cursor:count:onSuccess:onFailure:", "v52@0:8@16q24i32@?36@?44"};
static GGGaCountProbe GGGaBridgeHandler = {"FlutterServiceCallHandler", "handleMethodCall:args:result:", "B40@0:8@16@24@?32"};
static NSObject *GGGaBridgeNamesLock;
static NSMutableDictionary<NSString *, NSNumber *> *GGGaDispatchNames;
static NSMutableDictionary<NSString *, NSNumber *> *GGGaHandledNames;

static void GGGaRecordBridgeName(NSMutableDictionary<NSString *, NSNumber *> *names, id name) {
    if (![name isKindOfClass:NSString.class] || [name length] == 0 || [name length] > 90) return;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:-"] invertedSet];
    if ([name rangeOfCharacterFromSet:invalid].location != NSNotFound) return;
    @synchronized (GGGaBridgeNamesLock) {
        NSNumber *count = names[name];
        if (count || names.count < 32) names[name] = @(count.unsignedIntValue + 1);
    }
}

static void GGGaInstallCountProbe(GGGaCountProbe *probe, IMP replacement) {
    if (probe->original) return;
    Class cls = objc_getClass(probe->className);
    if (!cls) return;
    SEL selector = sel_registerName(probe->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || strcmp(method_getTypeEncoding(method), probe->encoding) != 0) return;
    probe->original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, probe->encoding);
}

static void GGGaInstallCountProbes(void) {
    if (!GGGaBridgeNamesLock) {
        GGGaBridgeNamesLock = [NSObject new];
        GGGaDispatchNames = [NSMutableDictionary new];
        GGGaHandledNames = [NSMutableDictionary new];
    }
    GGGaCountProbe *objectProbes[] = {&GGGaBridgeDispatch, &GGGaBridgeSend, &GGGaAlternateReceive};
    for (NSUInteger i = 0; i < sizeof(objectProbes) / sizeof(*objectProbes); i++) {
        GGGaCountProbe *probe = objectProbes[i];
        if (probe->original) continue;
        IMP imp = imp_implementationWithBlock(^(id object, id arg, id result) {
            atomic_fetch_add(&probe->hits, 1);
            if (probe == &GGGaBridgeDispatch) {
                Class callClass = NSClassFromString(@"FlutterMethodCall");
                SEL methodSelector = sel_registerName("method");
                if (callClass && [arg isKindOfClass:callClass] && [arg respondsToSelector:methodSelector]) {
                    id name = ((id (*)(id, SEL))objc_msgSend)(arg, methodSelector);
                    GGGaRecordBridgeName(GGGaDispatchNames, name);
                }
            }
            ((void (*)(id, SEL, id, id))probe->original)(object, sel_registerName(probe->selectorName), arg, result);
        });
        GGGaInstallCountProbe(probe, imp);
        if (!probe->original) imp_removeBlock(imp);
    }
    GGGaCountProbe *handler = &GGGaBridgeHandler;
    if (!handler->original) {
        IMP imp = imp_implementationWithBlock(^BOOL(id object, id name, id args, id result) {
            BOOL handled = ((BOOL (*)(id, SEL, id, id, id))handler->original)(
                object, sel_registerName(handler->selectorName), name, args, result);
            if (handled) {
                atomic_fetch_add(&handler->hits, 1);
                GGGaRecordBridgeName(GGGaHandledNames, name);
            }
            return handled;
        });
        GGGaInstallCountProbe(handler, imp);
        if (!handler->original) imp_removeBlock(imp);
    }

    GGGaCountProbe *listenerProbes[] = {&GGGaLocalHistory, &GGGaRemoteHistory};
    for (NSUInteger i = 0; i < sizeof(listenerProbes) / sizeof(*listenerProbes); i++) {
        GGGaCountProbe *probe = listenerProbes[i];
        if (probe->original) continue;
        IMP imp = imp_implementationWithBlock(^(id object, id conversation, long long cursor, int limit, id listener) {
            atomic_fetch_add(&probe->hits, 1);
            ((void (*)(id, SEL, id, long long, int, id))probe->original)(object, sel_registerName(probe->selectorName), conversation, cursor, limit, listener);
        });
        GGGaInstallCountProbe(probe, imp);
        if (!probe->original) imp_removeBlock(imp);
    }

    GGGaCountProbe *blockProbes[] = {&GGGaLocalHistoryBlock, &GGGaRemoteHistoryBlock};
    for (NSUInteger i = 0; i < sizeof(blockProbes) / sizeof(*blockProbes); i++) {
        GGGaCountProbe *probe = blockProbes[i];
        if (probe->original) continue;
        IMP imp = imp_implementationWithBlock(^(id object, id conversation, long long cursor, int limit, id success, id failure) {
            atomic_fetch_add(&probe->hits, 1);
            ((void (*)(id, SEL, id, long long, int, id, id))probe->original)(object, sel_registerName(probe->selectorName), conversation, cursor, limit, success, failure);
        });
        GGGaInstallCountProbe(probe, imp);
        if (!probe->original) imp_removeBlock(imp);
    }
}

static GGGaCountProbe *const GGGaCountProbes[] = {
    &GGGaBridgeDispatch, &GGGaBridgeHandler, &GGGaBridgeSend, &GGGaAlternateReceive,
    &GGGaLocalHistory, &GGGaLocalHistoryBlock, &GGGaRemoteHistory, &GGGaRemoteHistoryBlock
};

static NSString *GGGaProbeResult(GGGaCountProbe *probe) {
    if (!probe->original) return @"未安装";
    return [NSString stringWithFormat:@"+%u", atomic_load(&probe->hits) - probe->baseline];
}

static NSString *GGGaBridgeNameSummary(NSDictionary<NSString *, NSNumber *> *names) {
    NSArray<NSString *> *keys = [names keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];
    if (keys.count == 0) return @"无可显示的方法名";
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (NSString *key in keys) {
        if (lines.count == 5) break;
        [lines addObject:[NSString stringWithFormat:@"%@ ×%@", key, names[key]]];
    }
    if (keys.count > lines.count) {
        [lines addObject:[NSString stringWithFormat:@"另有 %lu 种", (unsigned long)(keys.count - lines.count)]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static id GGGaGet(id object, SEL selector) {
    return object && [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}
static void GGGaSet(id object, SEL selector, id value) {
    if (object && [object respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}
static long long GGGaGetNumber(id object, SEL selector) {
    return object && [object respondsToSelector:selector] ? ((long long (*)(id, SEL))objc_msgSend)(object, selector) : -1;
}
static void GGGaSetNumber(id object, SEL selector, long long value) {
    if (object && [object respondsToSelector:selector]) ((void (*)(id, SEL, long long))objc_msgSend)(object, selector, value);
}
static void GGGaCaptureSend(id service, id request, BOOL usesBlock) {
    if (request && objc_getAssociatedObject(request, &GGGaInternalRequestKey)) return;
    if (usesBlock) atomic_fetch_add(&GGGaBlockSendHits, 1);
    else atomic_fetch_add(&GGGaListenerSendHits, 1);
    if (![request isKindOfClass:NSClassFromString(@"AIMPubMsgSendMessage")]) {
        atomic_fetch_add(&GGGaSendWrongType, 1);
        return;
    }
    id content = GGGaGet(request, @selector(content));
    NSString *appCid = GGGaGet(request, @selector(appCid));
    if (![appCid isKindOfClass:NSString.class] || appCid.length == 0) {
        atomic_fetch_add(&GGGaSendMissingSession, 1);
        return;
    }
    NSArray *receivers = GGGaGet(request, @selector(receivers));
    if (![receivers isKindOfClass:NSArray.class] || receivers.count == 0) {
        atomic_fetch_add(&GGGaSendMissingReceivers, 1);
        return;
    }
    BOOL text = GGGaGet(content, @selector(textContent)) != nil;
    BOOL image = GGGaGet(content, @selector(imageContent)) != nil;
    if (!text && !image) {
        atomic_fetch_add(&GGGaSendOtherContent, 1);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (text) { GGGaTextTemplate = request; GGGaTextService = service; GGGaTextUsesBlock = usesBlock; }
        if (image) { GGGaImageTemplate = request; GGGaImageService = service; GGGaImageUsesBlock = usesBlock; }
        GGGaLatestAppCid = [appCid copy];
        GGGaLastCalibrationAt = [NSDate date];
    });
    atomic_fetch_add(&GGGaNativeSendCount, 1);
}

static id GGGaMakeRequest(id templateRequest, BOOL image, NSString **reason) {
    if (!templateRequest) { *reason = image ? @"请先在目标测试会话手动发送一张图片以校准参数。" : @"请先在目标测试会话手动发送一条文字以校准参数。"; return nil; }
    NSString *appCid = GGGaGet(templateRequest, @selector(appCid));
    NSArray *receivers = GGGaGet(templateRequest, @selector(receivers));
    if (!GGGaLastCalibrationAt || [GGGaLastCalibrationAt timeIntervalSinceNow] < -600) {
        *reason = @"校准已超过 10 分钟，请在目标测试会话重新手动发送一次。"; return nil;
    }
    if (![appCid isKindOfClass:NSString.class] || ![appCid isEqualToString:GGGaLatestAppCid] ||
        ![receivers isKindOfClass:NSArray.class] || receivers.count == 0) {
        *reason = @"校准会话不一致或缺少接收人，请在当前测试会话重新手动发送一次。"; return nil;
    }
    id oldContent = GGGaGet(templateRequest, @selector(content));
    id content = [NSClassFromString(@"AIMPubMsgContent") new];
    id request = [NSClassFromString(@"AIMPubMsgSendMessage") new];
    if (!content || !request) { *reason = @"当前版本未找到消息参数类。"; return nil; }
    long long contentType = GGGaGetNumber(oldContent, @selector(contentType));
    if (contentType < 0) { *reason = @"无法确定消息内容类型。"; return nil; }
    GGGaSetNumber(content, @selector(setContentType:), contentType);
    if (image) {
        id photo = GGGaGet(oldContent, @selector(imageContent));
        id mediaId = GGGaGet(photo, @selector(mediaId));
        id originalUrl = GGGaGet(photo, @selector(originalUrl));
        BOOL uploaded = ([mediaId isKindOfClass:NSString.class] && [mediaId length] > 0) ||
                        ([originalUrl isKindOfClass:NSString.class] && [originalUrl length] > 0);
        if (!uploaded) {
            *reason = @"捕获的图片缺少已上传媒体标识，无法直接复用。"; return nil;
        }
        GGGaSet(content, @selector(setImageContent:), photo);
    } else {
        id textContent = [NSClassFromString(@"AIMPubMsgTextContent") new];
        if (!textContent || !GGGaGet(oldContent, @selector(textContent))) { *reason = @"文字内容结构不匹配。"; return nil; }
        GGGaSet(textContent, @selector(setText:), GGGaDirectText);
        GGGaSet(textContent, @selector(setExtension:), GGGaGet(GGGaGet(oldContent, @selector(textContent)), @selector(extension)));
        GGGaSet(content, @selector(setTextContent:), textContent);
    }
    GGGaSet(request, @selector(setAppCid:), appCid);
    GGGaSet(request, @selector(setReceivers:), receivers);
    GGGaSet(request, @selector(setContent:), content);
    GGGaSet(request, @selector(setExtension:), GGGaGet(templateRequest, @selector(extension)));
    GGGaSet(request, @selector(setLocalExtension:), GGGaGet(templateRequest, @selector(localExtension)));
    objc_setAssociatedObject(request, &GGGaInternalRequestKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return request;
}

static void GGGaObservedSend(id self, SEL command, id message, id listener, id userData) {
    GGGaCaptureSend(self, message, NO);
    GGGaOriginalSend(self, command, message, listener, userData);
}

static void GGGaObservedBlockSend(id self, SEL command, id message, id progress, id success, id failure, id userData) {
    GGGaCaptureSend(self, message, YES);
    GGGaOriginalBlockSend(self, command, message, progress, success, failure, userData);
}

static void GGGaObservedOnMessage(id self, SEL command, id message) {
    atomic_fetch_add(&GGGaIncomingHits, 1);
    if (![message isKindOfClass:NSClassFromString(@"PMessage")] || ![message respondsToSelector:@selector(isMine)]) {
        atomic_fetch_add(&GGGaIncomingOtherType, 1);
    } else if (((BOOL (*)(id, SEL))objc_msgSend)(message, @selector(isMine))) {
        atomic_fetch_add(&GGGaIncomingOwn, 1);
    } else {
        id text = GGGaGet(GGGaGet(message, @selector(content)), @selector(text));
        if ([text isKindOfClass:NSString.class] && [text length] > 0) {
            atomic_fetch_add(&GGGaIncomingTextHits, 1);
            dispatch_async(dispatch_get_main_queue(), ^{ GGGaLastIncomingText = [text copy]; });
        } else {
            atomic_fetch_add(&GGGaIncomingNoText, 1);
        }
    }
    GGGaOriginalOnMessage(self, command, message);
}

static void GGGaInstallSendObserver(void) {
    Class service = objc_getClass("AIMPubMsgService");
    if (service && !GGGaSendHookInstalled) {
        Method method = class_getInstanceMethod(service, @selector(sendMessage:listener:userData:));
        if (method && strcmp(method_getTypeEncoding(method), "v40@0:8@16@24@32") == 0) {
            GGGaOriginalSend = (void (*)(id, SEL, id, id, id))method_setImplementation(method, (IMP)GGGaObservedSend);
            GGGaSendHookInstalled = GGGaOriginalSend != NULL;
        }
    }
    if (service && !GGGaBlockSendHookInstalled) {
        Method method = class_getInstanceMethod(service, @selector(sendMessageWithBlock:onProgress:onSuccess:onFailure:userData:));
        if (method && strcmp(method_getTypeEncoding(method), "v56@0:8@16@?24@?32@?40@48") == 0) {
            GGGaOriginalBlockSend = (void (*)(id, SEL, id, id, id, id, id))method_setImplementation(method, (IMP)GGGaObservedBlockSend);
            GGGaBlockSendHookInstalled = GGGaOriginalBlockSend != NULL;
        }
    }
    Class manager = objc_getClass("AIMManager");
    if (manager && !GGGaIncomingHookInstalled) {
        Method method = class_getInstanceMethod(manager, @selector(onMessage:));
        if (method && strcmp(method_getTypeEncoding(method), "v24@0:8@16") == 0) {
            GGGaOriginalOnMessage = (void (*)(id, SEL, id))method_setImplementation(method, (IMP)GGGaObservedOnMessage);
            GGGaIncomingHookInstalled = GGGaOriginalOnMessage != NULL;
        }
    }
}

@interface GGGaFloatingPage : UIView <WKNavigationDelegate, UITextFieldDelegate>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UILabel *webStatus;
@property(nonatomic, strong) UITextField *searchField;
@property(nonatomic, strong) UITextView *resultView;
@property(nonatomic, strong) UIButton *resultCopyButton;
@property(nonatomic, strong) NSURLSessionDataTask *request;
@property(nonatomic, assign) NSUInteger queryNumber;
@property(nonatomic, copy) void (^onClose)(void);
@property(nonatomic, copy) void (^onMenu)(void);
- (instancetype)initWithStoreSearch:(BOOL)storeSearch;
@end

@implementation GGGaFloatingPage
- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return button;
}

- (instancetype)initWithStoreSearch:(BOOL)storeSearch {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.backgroundColor = UIColor.systemBackgroundColor;
    self.layer.cornerRadius = 16;
    self.layer.borderColor = UIColor.separatorColor.CGColor;
    self.layer.borderWidth = 1;
    self.clipsToBounds = YES;

    UILabel *title = [UILabel new];
    title.text = storeSearch ? @"查门店" : @"aixiya.cn";
    title.font = [UIFont boldSystemFontOfSize:16];
    UIButton *menu = [self buttonWithTitle:@"菜单" action:@selector(openMenu)];
    UIButton *close = [self buttonWithTitle:@"关闭" action:@selector(closePage)];
    UIButton *utility = [self buttonWithTitle:storeSearch ? @"复制" : @"刷新"
                                      action:storeSearch ? @selector(copyResult) : @selector(loadWebsite)];
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, menu, utility, close]];
    header.spacing = 4;
    [header.heightAnchor constraintEqualToConstant:44].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10]
    ]];

    if (storeSearch) {
        self.resultCopyButton = utility;
        self.resultCopyButton.enabled = NO;
        self.searchField = [UITextField new];
        self.searchField.placeholder = @"输入门店关键词";
        self.searchField.borderStyle = UITextBorderStyleRoundedRect;
        self.searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
        self.searchField.returnKeyType = UIReturnKeySearch;
        self.searchField.delegate = self;
        UIButton *search = [self buttonWithTitle:@"查询" action:@selector(searchStores)];
        UIStackView *searchRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.searchField, search]];
        searchRow.spacing = 8;
        [searchRow.heightAnchor constraintEqualToConstant:44].active = YES;
        [stack addArrangedSubview:searchRow];

        self.resultView = [UITextView new];
        self.resultView.editable = NO;
        self.resultView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        self.resultView.text = @"输入关键词后，点「查询」。";
        [stack addArrangedSubview:self.resultView];
    } else {
        self.webStatus = [UILabel new];
        self.webStatus.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        self.webStatus.numberOfLines = 0;
        self.webStatus.hidden = YES;
        [stack addArrangedSubview:self.webStatus];

        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
        self.webView.navigationDelegate = self;
        self.webView.allowsBackForwardNavigationGestures = YES;
        [stack addArrangedSubview:self.webView];
        [self loadWebsite];
    }

    return self;
}

- (void)loadWebsite {
    self.webStatus.hidden = YES;
    if (self.webView.URL) {
        [self.webView reload];
    } else {
        [self.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://aixiya.cn/"]]];
    }
}

- (void)closePage {
    if (self.onClose) self.onClose();
}

- (void)openMenu {
    if (self.onMenu) self.onMenu();
}

- (void)copyResult {
    if (!self.resultCopyButton.enabled) return;
    UIPasteboard.generalPasteboard.string = self.resultView.text;
    [self.resultCopyButton setTitle:@"已复制" forState:UIControlStateNormal];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self searchStores];
    return NO;
}

- (void)searchStores {
    NSString *keyword = [self.searchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!keyword.length) return;
    [self.searchField resignFirstResponder];
    [self.request cancel];
    NSUInteger query = ++self.queryNumber;
    self.resultCopyButton.enabled = NO;
    [self.resultCopyButton setTitle:@"复制" forState:UIControlStateNormal];
    self.resultView.text = @"正在查询…";

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://aixiya.cn/api/mendian/"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:keyword]];
    components.percentEncodedQuery = [components.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    NSURL *url = components.URL;
    if (!url) {
        self.resultView.text = @"关键词无法编码。";
        return;
    }

    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    __weak GGGaFloatingPage *weakSelf = self;
    self.request = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSString *result = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            GGGaFloatingPage *page = weakSelf;
            if (!page || query != page.queryNumber) return;
            page.request = nil;
            if (error) {
                page.resultView.text = [NSString stringWithFormat:@"查询失败：%@", error.localizedDescription];
            } else if (status < 200 || status >= 300) {
                page.resultView.text = [NSString stringWithFormat:@"查询失败（HTTP %ld）。", (long)status];
            } else if (!result.length) {
                page.resultView.text = data.length ? @"返回内容无法按 UTF-8 读取。" : @"接口未返回内容。";
            } else {
                page.resultView.text = result;
                page.resultCopyButton.enabled = YES;
            }
            [page.resultView setContentOffset:CGPointZero animated:NO];
        });
    }];
    [self.request resume];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
 decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    if (action.targetFrame && !action.targetFrame.isMainFrame) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (![url.scheme.lowercaseString isEqualToString:@"https"]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    if (!action.targetFrame) {
        decisionHandler(WKNavigationActionPolicyCancel);
        [webView loadRequest:action.request];
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)showLoadError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    self.webStatus.text = [NSString stringWithFormat:@"网页加载失败：%@", error.localizedDescription];
    self.webStatus.hidden = NO;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.webStatus.hidden = YES;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    [self showLoadError:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error {
    [self showLoadError:error];
}
@end

@interface GGGaTestOverlay : UIView <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIButton *bubble;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *pageBackdrop;
@property(nonatomic, strong) GGGaFloatingPage *websitePage;
@property(nonatomic, strong) GGGaFloatingPage *storePage;
@property(nonatomic, weak) GGGaFloatingPage *activePage;
@property(nonatomic, weak) GGGaFloatingPage *lastPage;
@property(nonatomic, assign) BOOL positioned;
- (void)updateStatus;
- (void)sendTestImage:(BOOL)image;
- (void)showFloatingPage:(GGGaFloatingPage *)page;
- (void)updateBubbleLabel;
@end

static void GGGaCollectRenderViews(UIView *view, UIWindow *window, CGRect visibleArea,
                                   Class webViewClass, Class flutterViewClass,
                                   NSMutableArray<NSString *> *webViews,
                                   NSMutableArray<NSString *> *flutterViews) {
    if (view.hidden || view.alpha <= 0.01 || (view != window && view.window != window)) return;
    CGRect bounds = [view convertRect:view.bounds toView:window];
    CGRect visibleBounds = CGRectIntersection(bounds, visibleArea);
    if (!CGRectIsEmpty(visibleBounds)) {
        NSMutableArray<NSString *> *matches = nil;
        if (webViewClass && [view isKindOfClass:webViewClass]) matches = webViews;
        if (flutterViewClass && [view isKindOfClass:flutterViewClass]) matches = flutterViews;
        if (matches) {
            [matches addObject:[NSString stringWithFormat:@"%@  %@", NSStringFromClass(view.class), NSStringFromCGRect(visibleBounds)]];
        }
    }
    CGRect childArea = view.clipsToBounds ? visibleBounds : visibleArea;
    if (CGRectIsEmpty(childArea)) return;
    for (UIView *child in view.subviews) {
        GGGaCollectRenderViews(child, window, childArea, webViewClass, flutterViewClass, webViews, flutterViews);
    }
}

@implementation GGGaTestOverlay
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        GGGaInstallSendObserver();
        GGGaInstallCountProbes();
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.bubble = [UIButton buttonWithType:UIButtonTypeCustom];
        self.bubble.frame = CGRectMake(0, 0, 56, 56);
        self.bubble.backgroundColor = [UIColor colorWithRed:1 green:0.81 blue:0.18 alpha:1];
        [self.bubble setTitle:@"测试" forState:UIControlStateNormal];
        [self.bubble setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
        self.bubble.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        self.bubble.layer.cornerRadius = 28;
        self.bubble.layer.shadowColor = UIColor.blackColor.CGColor;
        self.bubble.layer.shadowOpacity = 0.22;
        self.bubble.layer.shadowRadius = 5;
        self.bubble.layer.shadowOffset = CGSizeMake(0, 2);
        self.bubble.accessibilityLabel = @"打开消息功能测试面板";
        [self.bubble addTarget:self action:@selector(tapBubble) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
        pan.delegate = self;
        [self.bubble addGestureRecognizer:pan];
        [self addSubview:self.bubble];
        self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 310, 412)];
        self.panel.backgroundColor = [UIColor colorWithWhite:0.97 alpha:0.98];
        self.panel.layer.cornerRadius = 14;
        self.panel.layer.shadowColor = UIColor.blackColor.CGColor;
        self.panel.layer.shadowOpacity = 0.3;
        self.panel.layer.shadowRadius = 8;
        self.panel.hidden = YES;
        [self addSubview:self.panel];
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, 280, 26)];
        title.text = @"消息功能测试 0.3.5";
        title.font = [UIFont boldSystemFontOfSize:18];
        [self.panel addSubview:title];
        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 39, 282, 106)];
        self.statusLabel.numberOfLines = 0;
        self.statusLabel.font = [UIFont systemFontOfSize:12];
        self.statusLabel.textColor = UIColor.darkGrayColor;
        [self.panel addSubview:self.statusLabel];
        NSArray<NSString *> *titles = @[@"打开网页", @"查门店", @"多路径结果", @"记录测试起点", @"桥接方法明细", @"检查网页容器", @"旧路径诊断", @"直接发文字", @"复用图片直发", @"最近捕获文字", @"清除校准", @"关闭"];
        NSArray<NSString *> *actions = @[@"openWebsite", @"openStoreSearch", @"showParallelDiagnostics", @"recordProbeBaseline", @"showBridgeDetails", @"showRenderDiagnostics", @"showPathDiagnostics", @"sendTextTest", @"sendImageTest", @"showLastIncoming", @"clearCalibration", @"togglePanel"];
        for (NSUInteger i = 0; i < titles.count; i++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.frame = CGRectMake(14 + (i % 2) * 146, 151 + (i / 2) * 43, 136, 36);
            button.backgroundColor = [UIColor colorWithWhite:0.89 alpha:1];
            button.layer.cornerRadius = 7;
            [button setTitle:titles[i] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:14];
            [button addTarget:self action:NSSelectorFromString(actions[i]) forControlEvents:UIControlEventTouchUpInside];
            [self.panel addSubview:button];
        }
        self.pageBackdrop = [UIButton buttonWithType:UIButtonTypeCustom];
        self.pageBackdrop.frame = self.bounds;
        self.pageBackdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.pageBackdrop.hidden = YES;
        self.pageBackdrop.accessibilityLabel = @"收起悬浮页面";
        [self.pageBackdrop addTarget:self action:@selector(minimizePage) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.pageBackdrop];
    }
    return self;
}
- (CGPoint)clampedCenter:(CGPoint)point {
    UIEdgeInsets inset = self.safeAreaInsets;
    CGFloat left = inset.left + 36, right = MAX(left, self.bounds.size.width - inset.right - 36);
    CGFloat top = inset.top + 36, bottom = MAX(top, self.bounds.size.height - inset.bottom - 36);
    return CGPointMake(MIN(MAX(point.x, left), right), MIN(MAX(point.y, top), bottom));
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!self.positioned) {
        self.bubble.center = CGPointMake(self.bounds.size.width - 42, self.bounds.size.height * 0.38);
        self.positioned = YES;
    }
    self.bubble.center = [self clampedCenter:self.bubble.center];
    CGFloat x = MIN(MAX(8, self.bubble.center.x - self.panel.bounds.size.width), MAX(8, self.bounds.size.width - self.panel.bounds.size.width - 8));
    CGFloat y = MIN(MAX(self.safeAreaInsets.top + 8, self.bubble.center.y - 115), MAX(self.safeAreaInsets.top + 8, self.bounds.size.height - self.safeAreaInsets.bottom - self.panel.bounds.size.height - 8));
    self.panel.frame = CGRectMake(x, y, self.panel.bounds.size.width, self.panel.bounds.size.height);
    CGRect safeArea = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat width = MAX(0, MIN(CGRectGetWidth(safeArea) - 24, 560));
    CGFloat height = MAX(0, MIN(CGRectGetHeight(safeArea) - 36, CGRectGetHeight(safeArea) * 0.77));
    CGRect pageFrame = CGRectMake(CGRectGetMidX(safeArea) - width / 2,
        CGRectGetMinY(safeArea) + 18, width, height);
    self.websitePage.frame = pageFrame;
    self.storePage.frame = pageFrame;
}
// The host receives touches outside the menu when no floating page is open.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
- (void)drag:(UIPanGestureRecognizer *)pan {
    CGPoint delta = [pan translationInView:self];
    self.bubble.center = [self clampedCenter:CGPointMake(self.bubble.center.x + delta.x, self.bubble.center.y + delta.y)];
    [self setNeedsLayout];
    [pan setTranslation:CGPointZero inView:self];
}
- (UIViewController *)presentingController {
    UIViewController *controller = self.window.rootViewController;
    while (controller) {
        if (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
            controller = controller.presentedViewController;
        } else if ([controller isKindOfClass:UINavigationController.class]) {
            UIViewController *next = ((UINavigationController *)controller).visibleViewController;
            if (!next) break;
            controller = next;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            UIViewController *next = ((UITabBarController *)controller).selectedViewController;
            if (!next) break;
            controller = next;
        } else { break; }
    }
    if (!controller || [controller isKindOfClass:UIAlertController.class] || !controller.view.window) return nil;
    return controller;
}
- (void)showNotice:(NSString *)message {
    UIViewController *controller = [self presentingController];
    if (!controller) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"GGGaTools · 发送测试" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}
- (void)togglePanel {
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) [self updateStatus];
}
- (void)tapBubble {
    if (!self.panel.hidden || !self.lastPage) {
        [self togglePanel];
    } else {
        [self showFloatingPage:self.lastPage];
    }
}
- (void)updateBubbleLabel {
    NSString *title = self.lastPage ? (self.lastPage == self.storePage ? @"门店" : @"网页") : @"测试";
    [self.bubble setTitle:title forState:UIControlStateNormal];
    self.bubble.accessibilityLabel = self.lastPage ?
        [NSString stringWithFormat:@"恢复悬浮%@", title] : @"打开消息功能测试面板";
}
- (void)minimizePage {
    [self.activePage endEditing:YES];
    self.activePage.hidden = YES;
    self.activePage = nil;
    self.pageBackdrop.hidden = YES;
    [self updateBubbleLabel];
}
- (GGGaFloatingPage *)newFloatingPageForStoreSearch:(BOOL)storeSearch {
    GGGaFloatingPage *page = [[GGGaFloatingPage alloc] initWithStoreSearch:storeSearch];
    __weak GGGaTestOverlay *overlay = self;
    page.onClose = ^{ [overlay minimizePage]; };
    page.onMenu = ^{
        [overlay minimizePage];
        [overlay togglePanel];
    };
    page.hidden = YES;
    [self addSubview:page];
    return page;
}
- (void)showFloatingPage:(GGGaFloatingPage *)page {
    if (self.activePage != page) [self minimizePage];
    self.panel.hidden = YES;
    self.lastPage = page;
    self.activePage = page;
    self.pageBackdrop.hidden = NO;
    page.hidden = NO;
    [self bringSubviewToFront:page];
    [self updateBubbleLabel];
    [self setNeedsLayout];
}
- (void)openWebsite {
    if (!self.websitePage) self.websitePage = [self newFloatingPageForStoreSearch:NO];
    [self showFloatingPage:self.websitePage];
}
- (void)openStoreSearch {
    if (!self.storePage) self.storePage = [self newFloatingPageForStoreSearch:YES];
    [self showFloatingPage:self.storePage];
}
- (void)updateStatus {
    NSString *session = GGGaLatestAppCid.length > 8 ? [GGGaLatestAppCid substringFromIndex:GGGaLatestAppCid.length - 8] : (GGGaLatestAppCid ?: @"无");
    self.statusLabel.text = [NSString stringWithFormat:@"SDK 监听：文字 %@ / 图片 %@ / 接收 %@\n已观察原生发送：%d 次；最近会话尾号：%@\n文字校准：%@；图片校准：%@\n请先在目标测试会话各手动发送一次文字和图片。", GGGaSendHookInstalled || GGGaBlockSendHookInstalled ? @"已安装" : @"未安装", GGGaImageTemplate ? @"已捕获" : @"待捕获", GGGaIncomingHookInstalled ? @"已安装" : @"未安装", atomic_load(&GGGaNativeSendCount), session, GGGaTextTemplate ? @"有" : @"无", GGGaImageTemplate ? @"有" : @"无"];
}
- (void)clearCalibration {
    GGGaTextTemplate = nil;
    GGGaImageTemplate = nil;
    GGGaTextService = nil;
    GGGaImageService = nil;
    GGGaLatestAppCid = nil;
    GGGaLastCalibrationAt = nil;
    GGGaLastIncomingText = nil;
    [self updateStatus];
}
- (void)showPathDiagnostics {
    [self updateStatus];
    NSString *message = [NSString stringWithFormat:
        @"发送监听安装：普通 %@ / Block %@\n发送入口命中：普通 %d / Block %d\n通过筛选 %d；参数类型不符 %d；无会话 %d；无接收人 %d；其他内容 %d\n\n接收监听安装：%@\n接收入口命中 %d；对象类型不符 %d；己方 %d；无文字 %d；对方文字 %d",
        GGGaSendHookInstalled ? @"是" : @"否", GGGaBlockSendHookInstalled ? @"是" : @"否",
        atomic_load(&GGGaListenerSendHits), atomic_load(&GGGaBlockSendHits), atomic_load(&GGGaNativeSendCount),
        atomic_load(&GGGaSendWrongType), atomic_load(&GGGaSendMissingSession),
        atomic_load(&GGGaSendMissingReceivers), atomic_load(&GGGaSendOtherContent),
        GGGaIncomingHookInstalled ? @"是" : @"否", atomic_load(&GGGaIncomingHits),
        atomic_load(&GGGaIncomingOtherType), atomic_load(&GGGaIncomingOwn),
        atomic_load(&GGGaIncomingNoText), atomic_load(&GGGaIncomingTextHits)];
    [self showNotice:message];
}
- (void)showRenderDiagnostics {
    UIWindow *window = self.window;
    if (!window) return;
    NSMutableArray<NSString *> *webViews = [NSMutableArray array];
    NSMutableArray<NSString *> *flutterViews = [NSMutableArray array];
    GGGaCollectRenderViews(window, window, window.bounds, NSClassFromString(@"WKWebView"),
                          NSClassFromString(@"FlutterView"), webViews, flutterViews);
    NSString *message = [NSString stringWithFormat:
        @"当前窗口内的可见布局区域\n\nWKWebView：%lu\n%@\n\nFlutterView：%lu\n%@",
        (unsigned long)webViews.count, [webViews componentsJoinedByString:@"\n"],
        (unsigned long)flutterViews.count, [flutterViews componentsJoinedByString:@"\n"]];
    [self showNotice:message];
}
- (void)recordProbeBaseline {
    GGGaInstallCountProbes();
    @synchronized (GGGaBridgeNamesLock) {
        [GGGaDispatchNames removeAllObjects];
        [GGGaHandledNames removeAllObjects];
    }
    for (NSUInteger i = 0; i < sizeof(GGGaCountProbes) / sizeof(*GGGaCountProbes); i++) {
        GGGaCountProbe *probe = GGGaCountProbes[i];
        probe->baseline = atomic_load(&probe->hits);
    }
    self.panel.hidden = YES;
}
- (void)showBridgeDetails {
    NSDictionary<NSString *, NSNumber *> *dispatchNames;
    NSDictionary<NSString *, NSNumber *> *handledNames;
    @synchronized (GGGaBridgeNamesLock) {
        dispatchNames = [GGGaDispatchNames copy];
        handledNames = [GGGaHandledNames copy];
    }
    NSString *message = [NSString stringWithFormat:@"分发 %@\n%@\n\n处理成功 %@\n%@",
        GGGaProbeResult(&GGGaBridgeDispatch), GGGaBridgeNameSummary(dispatchNames),
        GGGaProbeResult(&GGGaBridgeHandler), GGGaBridgeNameSummary(handledNames)];
    [self showNotice:message];
}
- (void)showParallelDiagnostics {
    NSString *message = [NSString stringWithFormat:
        @"起点之后的调用次数\n\nFlutter 桥接：分发 %@ / 消息 %@\n原生备用接收：%@\n本地历史：监听器 %@ / Block %@\n远端历史：监听器 %@ / Block %@\n\nFFI 符号可查找性（非调用次数）\n发送 %@ / 接收注册 %@ / 历史 %@",
        GGGaProbeResult(&GGGaBridgeDispatch), GGGaProbeResult(&GGGaBridgeSend),
        GGGaProbeResult(&GGGaAlternateReceive), GGGaProbeResult(&GGGaLocalHistory),
        GGGaProbeResult(&GGGaLocalHistoryBlock), GGGaProbeResult(&GGGaRemoteHistory),
        GGGaProbeResult(&GGGaRemoteHistoryBlock),
        dlsym(RTLD_DEFAULT, "SendMessage") ? @"是" : @"否",
        dlsym(RTLD_DEFAULT, "AddMsgListener") ? @"是" : @"否",
        dlsym(RTLD_DEFAULT, "ListPreviousMessage") ? @"是" : @"否"];
    [self showNotice:message];
}
- (void)sendTextTest { [self sendTestImage:NO]; }
- (void)sendImageTest { [self sendTestImage:YES]; }
- (void)sendTestImage:(BOOL)image {
    NSString *reason = nil;
    id templateRequest = image ? GGGaImageTemplate : GGGaTextTemplate;
    id service = image ? GGGaImageService : GGGaTextService;
    BOOL usesBlock = image ? GGGaImageUsesBlock : GGGaTextUsesBlock;
    id request = GGGaMakeRequest(templateRequest, image, &reason);
    if (!request || !service || (usesBlock ? !GGGaBlockSendHookInstalled : !GGGaSendHookInstalled)) {
        [self showNotice:reason ?: @"发送服务尚未捕获，请在目标测试会话手动发送一次后刷新状态。"];
        return;
    }
    UIViewController *controller = [self presentingController];
    if (!controller) return;
    NSString *session = GGGaLatestAppCid.length > 8 ? [GGGaLatestAppCid substringFromIndex:GGGaLatestAppCid.length - 8] : GGGaLatestAppCid;
    NSString *detail = image ? @"复用该会话最近一次手动发送的图片媒体。" : GGGaDirectText;
    NSString *message = [NSString stringWithFormat:@"将直接调用消息 SDK，向最近校准会话（尾号 %@）发送：\n%@\n\n请确认仍在该测试会话。点击发送后无法由插件撤回。", session, detail];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:image ? @"确认直接发送图片" : @"确认直接发送文字" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"直接发送" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        @try {
            if (usesBlock) GGGaOriginalBlockSend(service, @selector(sendMessageWithBlock:onProgress:onSuccess:onFailure:userData:), request, nil, nil, nil, nil);
            else GGGaOriginalSend(service, @selector(sendMessage:listener:userData:), request, nil, nil);
            [self showNotice:@"已调用消息 SDK。请检查聊天中是否出现消息及对方是否收到；此提示不代表服务端发送成功。"];
        } @catch (NSException *exception) {
            [self showNotice:[NSString stringWithFormat:@"SDK 调用异常：%@", exception.name]];
        }
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
}
- (void)showLastIncoming {
    NSString *message = GGGaLastIncomingText;
    [self showNotice:message.length ? [NSString stringWithFormat:@"最近捕获的对方文字（尚不能证明属于当前会话）：\n%@", message] : @"尚未捕获对方文字。请让测试会话中的对方发来一条新消息，再点此按钮。当前版本可能走另一条接收路径。"];
}
@end

@interface GGGaTestManager : NSObject
@property(nonatomic, strong) NSMapTable<UIWindow *, GGGaTestOverlay *> *overlays;
@property(nonatomic, strong) NSTimer *timer;
- (void)refresh;
@end

@implementation GGGaTestManager
- (instancetype)init {
    self = [super init];
    if (self) {
        self.overlays = [NSMapTable weakToStrongObjectsMapTable];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(onNotification:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(onNotification:) name:UISceneDidActivateNotification object:nil];
        [nc addObserver:self selector:@selector(onNotification:) name:UIWindowDidBecomeKeyNotification object:nil];
        // A modest foreground watchdog restores the button after host view changes.
        self.timer = [NSTimer timerWithTimeInterval:2 target:self selector:@selector(onTimer:) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
        [self refresh];
    }
    return self;
}
- (void)onNotification:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}
- (void)onTimer:(NSTimer *)timer { GGGaInstallSendObserver(); [self refresh]; }
- (void)attachToWindow:(UIWindow *)window {
    if (!window || window.hidden || window.alpha < 0.01 || !window.rootViewController || window.windowLevel != UIWindowLevelNormal) return;
    GGGaTestOverlay *overlay = [self.overlays objectForKey:window];
    if (!overlay) {
        overlay = [[GGGaTestOverlay alloc] initWithFrame:window.bounds];
        [self.overlays setObject:overlay forKey:window];
    }
    if (overlay.superview != window) [window addSubview:overlay];
    overlay.frame = window.bounds;
    [window bringSubviewToFront:overlay];
}
- (void)refresh {
    UIApplication *app = UIApplication.sharedApplication;
    if (app.applicationState != UIApplicationStateActive) return;
    BOOL foundScene = NO;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        foundScene = YES;
        UIWindow *candidate = nil;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha < 0.01 || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) continue;
            if (!candidate || window.isKeyWindow) candidate = window;
            if (window.isKeyWindow) break;
        }
        [self attachToWindow:candidate];
    }
    if (!foundScene) {
        for (UIWindow *window in app.windows) {
            if (window.isKeyWindow) { [self attachToWindow:window]; break; }
        }
    }
}
@end

__attribute__((constructor)) static void GGGaToolsInitialize(void) {
    @autoreleasepool {
        if ([NSBundle.mainBundle.bundlePath.pathExtension.lowercaseString isEqualToString:@"appex"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            static GGGaTestManager *manager;
            if (!manager) manager = [[GGGaTestManager alloc] init];
            NSLog(@"[GGGaTools] 0.3.5 message test loaded");
        });
    }
}
