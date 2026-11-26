#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const GGGaMenuURL = @"https://aixiya.cn/api/gggatools/menu.json";

static BOOL GGGaNonemptyString(id value) {
    return [value isKindOfClass:NSString.class] &&
        [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
}

static NSURL *GGGaHTTPSURL(id value) {
    if (!GGGaNonemptyString(value)) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    if (![parts.scheme.lowercaseString isEqualToString:@"https"] || !parts.host.length || parts.user || parts.password) return nil;
    return parts.URL;
}

static NSArray<NSDictionary *> *GGGaMenuItems(NSData *data) {
    if (!data.length || data.length > 256 * 1024) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"schemaVersion"] isEqual:@1]) return nil;
    id items = root[@"items"];
    if (![items isKindOfClass:NSArray.class]) return nil;

    NSMutableSet *identifiers = [NSMutableSet new];
    for (id item in items) {
        if (![item isKindOfClass:NSDictionary.class] ||
            !GGGaNonemptyString(item[@"id"]) || !GGGaNonemptyString(item[@"title"]) ||
            !GGGaHTTPSURL(item[@"url"]) || [identifiers containsObject:item[@"id"]]) return nil;
        [identifiers addObject:item[@"id"]];
        if ([item[@"type"] isEqual:@"web"]) continue;
        if (![item[@"type"] isEqual:@"api"] || ![item[@"method"] isEqual:@"GET"] ||
            ![item[@"response"] isEqual:@"text"]) return nil;
        id input = item[@"input"];
        if (![input isKindOfClass:NSDictionary.class] || !GGGaNonemptyString(input[@"parameter"]) ||
            (input[@"placeholder"] && ![input[@"placeholder"] isKindOfClass:NSString.class])) return nil;
    }
    return items;
}

static NSURLSession *GGGaHTTPSession(void) {
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPShouldSetCookies = NO;
        configuration.URLCredentialStorage = nil;
        configuration.URLCache = nil;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

@interface GGGaFloatingPage : UIView <WKNavigationDelegate, UITextFieldDelegate>
@property(nonatomic, copy) NSDictionary *item;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UILabel *webStatus;
@property(nonatomic, strong) UITextField *searchField;
@property(nonatomic, strong) UITextView *resultView;
@property(nonatomic, strong) UIButton *resultCopyButton;
@property(nonatomic, strong) NSURLSessionDataTask *request;
@property(nonatomic, assign) NSUInteger queryNumber;
@property(nonatomic, copy) void (^onClose)(void);
@property(nonatomic, copy) void (^onMenu)(void);
- (instancetype)initWithItem:(NSDictionary *)item;
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

- (instancetype)initWithItem:(NSDictionary *)item {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.item = item;
    BOOL storeSearch = [item[@"type"] isEqual:@"api"];
    self.backgroundColor = UIColor.systemBackgroundColor;
    self.layer.cornerRadius = 16;
    self.layer.borderColor = UIColor.separatorColor.CGColor;
    self.layer.borderWidth = 1;
    self.clipsToBounds = YES;

    UILabel *title = [UILabel new];
    title.text = item[@"title"];
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
        self.searchField.placeholder = item[@"input"][@"placeholder"] ?: @"输入查询内容";
        self.searchField.borderStyle = UITextBorderStyleRoundedRect;
        self.searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
        self.searchField.returnKeyType = UIReturnKeySearch;
        self.searchField.delegate = self;
        UIButton *search = [self buttonWithTitle:@"查询" action:@selector(runQuery)];
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
        [self.webView loadRequest:[NSURLRequest requestWithURL:GGGaHTTPSURL(self.item[@"url"])]];
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
    [self runQuery];
    return NO;
}

- (void)runQuery {
    NSString *keyword = [self.searchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!keyword.length) return;
    [self.searchField resignFirstResponder];
    [self.request cancel];
    NSUInteger query = ++self.queryNumber;
    self.resultCopyButton.enabled = NO;
    [self.resultCopyButton setTitle:@"复制" forState:UIControlStateNormal];
    self.resultView.text = @"正在查询…";

    NSURLComponents *components = [NSURLComponents componentsWithString:self.item[@"url"]];
    NSString *parameter = self.item[@"input"][@"parameter"];
    NSMutableArray *items = [NSMutableArray new];
    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isEqualToString:parameter]) [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:parameter value:keyword]];
    components.queryItems = items;
    components.percentEncodedQuery = [components.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    NSURL *url = components.URL;
    if (!url) {
        self.resultView.text = @"关键词无法编码。";
        return;
    }

    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    __weak GGGaFloatingPage *weakSelf = self;
    self.request = [GGGaHTTPSession() dataTaskWithRequest:request completionHandler:
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

@interface GGGaToolsOverlay : UIView
@property(nonatomic, strong) UIButton *bubble;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UIScrollView *menuScroll;
@property(nonatomic, strong) UIStackView *menuRows;
@property(nonatomic, copy) NSArray<NSDictionary *> *menuItems;
@property(nonatomic, strong) NSURLSessionDataTask *menuRequest;
@property(nonatomic, strong) UIButton *pageBackdrop;
@property(nonatomic, strong) NSMutableDictionary<NSString *, GGGaFloatingPage *> *pages;
@property(nonatomic, weak) GGGaFloatingPage *activePage;
@property(nonatomic, weak) GGGaFloatingPage *lastPage;
@property(nonatomic, assign) BOOL positioned;
- (void)showFloatingPage:(GGGaFloatingPage *)page;
- (void)updateBubbleLabel;
- (void)loadRemoteMenu;
@end

@implementation GGGaToolsOverlay
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.bubble = [UIButton buttonWithType:UIButtonTypeCustom];
        self.bubble.frame = CGRectMake(0, 0, 56, 56);
        self.bubble.backgroundColor = [UIColor colorWithRed:1 green:0.81 blue:0.18 alpha:1];
        [self.bubble setTitle:@"工具" forState:UIControlStateNormal];
        [self.bubble setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
        self.bubble.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        self.bubble.layer.cornerRadius = 28;
        self.bubble.layer.shadowColor = UIColor.blackColor.CGColor;
        self.bubble.layer.shadowOpacity = 0.22;
        self.bubble.layer.shadowRadius = 5;
        self.bubble.layer.shadowOffset = CGSizeMake(0, 2);
        self.bubble.accessibilityLabel = @"打开便捷工具菜单";
        [self.bubble addTarget:self action:@selector(tapBubble) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
        [self.bubble addGestureRecognizer:pan];
        [self addSubview:self.bubble];
        self.pages = [NSMutableDictionary new];
        self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 248, 112)];
        self.panel.backgroundColor = UIColor.secondarySystemBackgroundColor;
        self.panel.layer.cornerRadius = 14;
        self.panel.layer.shadowColor = UIColor.blackColor.CGColor;
        self.panel.layer.shadowOpacity = 0.3;
        self.panel.layer.shadowRadius = 8;
        self.panel.hidden = YES;
        [self addSubview:self.panel];
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 11, 216, 27)];
        title.text = @"便捷工具";
        title.font = [UIFont boldSystemFontOfSize:18];
        [self.panel addSubview:title];
        self.menuScroll = [UIScrollView new];
        self.menuScroll.translatesAutoresizingMaskIntoConstraints = NO;
        [self.panel addSubview:self.menuScroll];
        self.menuRows = [UIStackView new];
        self.menuRows.axis = UILayoutConstraintAxisVertical;
        self.menuRows.spacing = 6;
        self.menuRows.translatesAutoresizingMaskIntoConstraints = NO;
        [self.menuScroll addSubview:self.menuRows];
        [NSLayoutConstraint activateConstraints:@[
            [self.menuScroll.topAnchor constraintEqualToAnchor:self.panel.topAnchor constant:45],
            [self.menuScroll.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor constant:-10],
            [self.menuScroll.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor constant:12],
            [self.menuScroll.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor constant:-12],
            [self.menuRows.topAnchor constraintEqualToAnchor:self.menuScroll.contentLayoutGuide.topAnchor],
            [self.menuRows.bottomAnchor constraintEqualToAnchor:self.menuScroll.contentLayoutGuide.bottomAnchor],
            [self.menuRows.leadingAnchor constraintEqualToAnchor:self.menuScroll.contentLayoutGuide.leadingAnchor],
            [self.menuRows.trailingAnchor constraintEqualToAnchor:self.menuScroll.contentLayoutGuide.trailingAnchor],
            [self.menuRows.widthAnchor constraintEqualToAnchor:self.menuScroll.frameLayoutGuide.widthAnchor]
        ]];
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
    CGRect safeArea = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat menuWidth = MIN(248, MAX(0, CGRectGetWidth(safeArea) - 16));
    NSUInteger rows = MAX(1, self.menuRows.arrangedSubviews.count);
    CGFloat menuHeight = MIN(55 + rows * 50 - 6, MAX(0, CGRectGetHeight(safeArea) - 16));
    CGFloat left = CGRectGetMinX(safeArea) + 8;
    CGFloat right = MAX(left, CGRectGetMaxX(safeArea) - menuWidth - 8);
    CGFloat x = CGRectGetMinX(self.bubble.frame) - menuWidth - 6;
    if (x < left) x = CGRectGetMaxX(self.bubble.frame) + 6;
    x = MIN(MAX(x, left), right);
    CGFloat top = CGRectGetMinY(safeArea) + 8;
    CGFloat y = MIN(MAX(top, self.bubble.center.y - menuHeight / 2),
                    MAX(top, CGRectGetMaxY(safeArea) - menuHeight - 8));
    self.panel.frame = CGRectMake(x, y, menuWidth, menuHeight);
    if (!self.panel.hidden) [self bringSubviewToFront:self.bubble];
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
- (void)togglePanel {
    self.panel.hidden = !self.panel.hidden;
    if (!self.panel.hidden) [self loadRemoteMenu];
}
- (void)redrawMenuWithMessage:(NSString *)message retry:(BOOL)retry {
    for (UIView *row in self.menuRows.arrangedSubviews) {
        [self.menuRows removeArrangedSubview:row];
        [row removeFromSuperview];
    }
    if (message) {
        UILabel *label = [UILabel new];
        label.text = message;
        label.font = [UIFont systemFontOfSize:14];
        label.textColor = UIColor.secondaryLabelColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.adjustsFontSizeToFitWidth = YES;
        [label.heightAnchor constraintEqualToConstant:44].active = YES;
        [self.menuRows addArrangedSubview:label];
    }
    if (retry || !message) {
        NSUInteger count = retry ? 1 : self.menuItems.count;
        for (NSUInteger i = 0; i < count; i++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = (NSInteger)i;
            button.backgroundColor = UIColor.tertiarySystemFillColor;
            button.layer.cornerRadius = 9;
            [button setTitle:retry ? @"重试" : self.menuItems[i][@"title"] forState:UIControlStateNormal];
            button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            [button.heightAnchor constraintEqualToConstant:44].active = YES;
            [button addTarget:self action:retry ? @selector(loadRemoteMenu) : @selector(selectMenuItem:) forControlEvents:UIControlEventTouchUpInside];
            [self.menuRows addArrangedSubview:button];
        }
    }
    [self.menuScroll setContentOffset:CGPointZero animated:NO];
    [self setNeedsLayout];
}
- (void)applyRemoteItems:(NSArray<NSDictionary *> *)items {
    NSMutableDictionary *byID = [NSMutableDictionary new];
    for (NSDictionary *item in items) byID[item[@"id"]] = item;
    for (NSString *identifier in self.pages.allKeys) {
        GGGaFloatingPage *page = self.pages[identifier];
        if ([page.item isEqual:byID[identifier]]) continue;
        if (self.activePage == page) [self minimizePage];
        if (self.lastPage == page) self.lastPage = nil;
        [page.request cancel];
        [page removeFromSuperview];
        [self.pages removeObjectForKey:identifier];
    }
    self.menuItems = items;
    [self updateBubbleLabel];
    [self redrawMenuWithMessage:items.count ? nil : @"服务器没有配置按钮" retry:NO];
}
- (void)loadRemoteMenu {
    if (self.menuRequest) return;
    self.menuItems = nil;
    [self redrawMenuWithMessage:@"正在读取服务器菜单…" retry:NO];

    NSURL *url = [NSURL URLWithString:GGGaMenuURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    __weak GGGaToolsOverlay *weakSelf = self;
    self.menuRequest = [GGGaHTTPSession() dataTaskWithRequest:request completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        BOOL sameOrigin = [response.URL.scheme.lowercaseString isEqualToString:url.scheme] &&
            [response.URL.host.lowercaseString isEqualToString:url.host] &&
            (response.URL.port == nil || [response.URL.port isEqual:@443]);
        NSArray *items = !error && status == 200 && sameOrigin ? GGGaMenuItems(data) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            GGGaToolsOverlay *overlay = weakSelf;
            if (!overlay) return;
            overlay.menuRequest = nil;
            if (items) {
                [overlay applyRemoteItems:items];
            } else {
                NSString *message = error ? @"读取失败，请检查网络" :
                    (status != 200 ? [NSString stringWithFormat:@"读取失败（HTTP %ld）", (long)status] :
                     @"菜单地址或配置格式不正确");
                [overlay redrawMenuWithMessage:message retry:YES];
            }
        });
    }];
    [self.menuRequest resume];
}
- (void)tapBubble {
    if (!self.panel.hidden || !self.lastPage) {
        [self togglePanel];
    } else {
        [self showFloatingPage:self.lastPage];
    }
}
- (void)updateBubbleLabel {
    NSString *title = self.lastPage ? ([self.lastPage.item[@"type"] isEqual:@"api"] ? @"查询" : @"网页") : @"工具";
    [self.bubble setTitle:title forState:UIControlStateNormal];
    self.bubble.accessibilityLabel = self.lastPage ?
        [NSString stringWithFormat:@"恢复悬浮%@", title] : @"打开便捷工具菜单";
}
- (void)minimizePage {
    [self.activePage endEditing:YES];
    self.activePage.hidden = YES;
    self.activePage = nil;
    self.pageBackdrop.hidden = YES;
    [self updateBubbleLabel];
}
- (GGGaFloatingPage *)newFloatingPageForItem:(NSDictionary *)item {
    GGGaFloatingPage *page = [[GGGaFloatingPage alloc] initWithItem:item];
    __weak GGGaToolsOverlay *overlay = self;
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
- (void)selectMenuItem:(UIButton *)button {
    if (button.tag < 0 || (NSUInteger)button.tag >= self.menuItems.count) return;
    NSDictionary *item = self.menuItems[(NSUInteger)button.tag];
    NSString *identifier = item[@"id"];
    GGGaFloatingPage *page = self.pages[identifier];
    if (!page) {
        page = [self newFloatingPageForItem:item];
        self.pages[identifier] = page;
    }
    [self showFloatingPage:page];
}
@end

@interface GGGaOverlayManager : NSObject
@property(nonatomic, strong) NSMapTable<UIWindow *, GGGaToolsOverlay *> *overlays;
@property(nonatomic, strong) NSTimer *timer;
- (void)refresh;
@end

@implementation GGGaOverlayManager
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
- (void)onTimer:(NSTimer *)timer { [self refresh]; }
- (void)attachToWindow:(UIWindow *)window {
    if (!window || window.hidden || window.alpha < 0.01 || !window.rootViewController || window.windowLevel != UIWindowLevelNormal) return;
    GGGaToolsOverlay *overlay = [self.overlays objectForKey:window];
    if (!overlay) {
        overlay = [[GGGaToolsOverlay alloc] initWithFrame:window.bounds];
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
            static GGGaOverlayManager *manager;
            if (!manager) manager = [[GGGaOverlayManager alloc] init];
            NSLog(@"[GGGaTools] 0.3.6 floating tools loaded");
        });
    }
}
