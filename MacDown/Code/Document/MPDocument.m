//
//  MPDocument.m
//  MacDown
//
//  Created by Tzu-ping Chung  on 6/06/2014.
//  Copyright (c) 2014 Tzu-ping Chung . All rights reserved.
//

#import "MPDocument.h"
#import <WebKit/WebKit.h>
#import <hoedown/html.h>
#import <hoedown/markdown.h>
#import "hoedown_html_patch.h"
#import "HGMarkdownHighlighter.h"
#import "MPUtilities.h"
#import "NSString+Lookup.h"
#import "NSTextView+Autocomplete.h"
#import "MPPreferences.h"
#import "MPExportPanelAccessoryViewController.h"


@implementation MPPreferences (Hoedown)
- (int)extensionFlags
{
    int flags = HOEDOWN_EXT_LAX_SPACING;
    if (self.extensionAutolink)
        flags |= HOEDOWN_EXT_AUTOLINK;
    if (self.extensionFencedCode)
        flags |= HOEDOWN_EXT_FENCED_CODE;
    if (self.extensionFootnotes)
        flags |= HOEDOWN_EXT_FOOTNOTES;
    if (self.extensionHighlight)
        flags |= HOEDOWN_EXT_HIGHLIGHT;
    if (!self.extensionIntraEmphasis)
        flags |= HOEDOWN_EXT_NO_INTRA_EMPHASIS;
    if (self.extensionQuote)
        flags |= HOEDOWN_EXT_QUOTE;
    if (self.extensionStrikethough)
        flags |= HOEDOWN_EXT_STRIKETHROUGH;
    if (self.extensionSuperscript)
        flags |= HOEDOWN_EXT_SUPERSCRIPT;
    if (self.extensionTables)
        flags |= HOEDOWN_EXT_TABLES;
    if (self.extensionUnderline)
        flags |= HOEDOWN_EXT_UNDERLINE;
    return flags;
}
@end


@interface MPDocument () <NSTextViewDelegate>

@property (unsafe_unretained) IBOutlet NSTextView *editor;
@property (weak) IBOutlet WebView *preview;
@property (nonatomic, unsafe_unretained) hoedown_renderer *htmlRenderer;
@property HGMarkdownHighlighter *highlighter;
@property int currentExtensionFlags;
@property BOOL currentSmartyPantsFlag;
@property (copy) NSString *currentHtml;
@property (copy) NSString *currentStyleName;
@property BOOL currentSyntaxHighlighting;
@property (strong) NSTimer *parseDelayTimer;
@property (readonly) NSArray *stylesheets;
@property (readonly) NSArray *scripts;

// Store file content in initializer until nib is loaded.
@property (copy) NSString *loadedString;

@end


@implementation MPDocument

- (id)init
{
    self = [super init];
    if (!self)
        return self;

    self.htmlRenderer = hoedown_html_renderer_new(0, 0);
    self.htmlRenderer->blockcode = hoedown_patch_render_blockcode;

    return self;
}

- (void)dealloc
{
    self.htmlRenderer = NULL;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self
                      name:NSTextDidChangeNotification
                    object:self.editor];
    [center removeObserver:self
                      name:NSUserDefaultsDidChangeNotification
                    object:[NSUserDefaults standardUserDefaults]];
    [center removeObserver:self
                      name:NSViewBoundsDidChangeNotification
                    object:self.editor.enclosingScrollView.contentView];
}


#pragma mark - Accessor

- (MPPreferences *)preferences
{
    return [MPPreferences sharedInstance];
}

- (void)setHtmlRenderer:(hoedown_renderer *)htmlRenderer
{
    if (_htmlRenderer)
        hoedown_html_renderer_free(_htmlRenderer);
    _htmlRenderer = htmlRenderer;
}

- (NSArray *)stylesheets
{
    NSString *defaultStyle = MPStylePathForName(self.preferences.htmlStyleName);
    NSMutableArray *styles = [NSMutableArray arrayWithObject:defaultStyle];
    if (self.preferences.htmlSyntaxHighlighting)
    {
        [styles addObject:[[NSBundle mainBundle] pathForResource:@"prism"
                                                          ofType:@"css"]];
    }
    return styles;
}

- (NSArray *)scripts
{
    if (self.preferences.htmlSyntaxHighlighting)
        return @[[[NSBundle mainBundle] pathForResource:@"prism" ofType:@"js"]];
    return @[];
}


#pragma mark - Override

- (NSString *)windowNibName
{
    return @"MPDocument";
}

- (void)windowControllerDidLoadNib:(NSWindowController *)controller
{
    [super windowControllerDidLoadNib:controller];

    // All files use their absolute path to keep their window states.
    // New files share a common autosave name so that we can get a preferred
    // window size when creating new documents.
    NSString *autosaveName = @"Markdown";
    if (self.fileURL)
        autosaveName = self.fileURL.absoluteString;
    controller.window.frameAutosaveName = autosaveName;

    self.highlighter =
        [[HGMarkdownHighlighter alloc] initWithTextView:self.editor
                                           waitInterval:0.1];
    self.highlighter.parseAndHighlightAutomatically = YES;
    self.highlighter.resetTypingAttributes = YES;

    // Fix Xcod 5/Lion bug where disselecting options in OB doesn't work.
    // TODO: Can we save/set these app-wise using KVO?
    self.editor.automaticQuoteSubstitutionEnabled = NO;
    self.editor.automaticLinkDetectionEnabled = NO;
    self.editor.automaticDashSubstitutionEnabled = NO;

    [self setupEditor];
    if (self.loadedString)
    {
        self.editor.string = self.loadedString;
        self.loadedString = nil;
        [self parse];
        [self render];
    }

    self.preview.frameLoadDelegate = self;
    self.preview.policyDelegate = self;

    [self.highlighter activate];
    [self.highlighter parseAndHighlightNow];    // Initial highlighting

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(textDidChange:)
                   name:NSTextDidChangeNotification
                 object:self.editor];
    [center addObserver:self
               selector:@selector(userDefaultsDidChange:)
                   name:NSUserDefaultsDidChangeNotification
                 object:[NSUserDefaults standardUserDefaults]];
    [center addObserver:self
               selector:@selector(boundsDidChange:)
                   name:NSViewBoundsDidChangeNotification
                 object:self.editor.enclosingScrollView.contentView];
}

+ (BOOL)autosavesInPlace
{
    return YES;
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError
{
    return [self.editor.string dataUsingEncoding:NSUTF8StringEncoding];
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName
               error:(NSError **)outError
{
    self.loadedString = [[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding];
    return YES;
}

- (BOOL)prepareSavePanel:(NSSavePanel *)savePanel
{
    NSString *title = [self.editor.string titleString];
    if (title)
        savePanel.nameFieldStringValue = title;
    return [super prepareSavePanel:savePanel];
}

- (NSPrintOperation *)printOperationWithSettings:(NSDictionary *)printSettings
                                           error:(NSError *__autoreleasing *)e
{
    WebFrameView *frameView = self.preview.mainFrame.frameView;
    NSPrintInfo *printInfo = self.printInfo;
    return [frameView printOperationWithPrintInfo:printInfo];
}


#pragma mark - NSTextViewDelegate

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
    if (commandSelector == @selector(insertTab:))
        return ![self textViewShouldInsertTab:textView];
    else if (commandSelector == @selector(insertNewline:))
        return ![self textViewShouldInsertNewline:textView];
    else if (commandSelector == @selector(deleteBackward:))
        return ![self textViewShouldDeleteBackward:textView];
    return NO;
}

- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)range
                                              replacementString:(NSString *)str
{
    if (self.preferences.editorCompleteMatchingCharacters)
    {
        BOOL strikethrough = self.preferences.extensionStrikethough;
        if ([textView completeMatchingCharactersForTextInRange:range
                                                    withString:str
                                          strikethroughEnabled:strikethrough])
            return NO;
    }
    return YES;
}


#pragma mark - Fake NSTextViewDelegate

- (BOOL)textViewShouldInsertTab:(NSTextView *)textView
{
    if (self.preferences.editorConvertTabs)
    {
        [textView insertSpacesForTab];
        return NO;
    }
    return YES;
}

- (BOOL)textViewShouldInsertNewline:(NSTextView *)textView
{
    if ([textView insertMappedContent])
        return NO;
    if ([textView completeNextLine])
        return NO;
    return YES;
}

- (BOOL)textViewShouldDeleteBackward:(NSTextView *)textView
{
    if (self.preferences.editorCompleteMatchingCharacters)
    {
        NSUInteger location = self.editor.selectedRange.location;
        if ([textView deleteMatchingCharactersAround:location])
            return NO;
    }
    if (self.preferences.editorConvertTabs)
    {
        NSUInteger location = self.editor.selectedRange.location;
        if ([textView unindentForSpacesBefore:location])
            return NO;
    }
    return YES;
}


#pragma mark - WebFrameLoadDelegate

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    [self syncScrollers];
}


#pragma mark - WebPolicyDelegate

- (void)webView:(WebView *)webView
                decidePolicyForNavigationAction:(NSDictionary *)information
        request:(NSURLRequest *)request frame:(WebFrame *)frame
                decisionListener:(id<WebPolicyDecisionListener>)listener
{
    NSURL *oldUrl = information[WebActionOriginalURLKey];
    NSURL *newUrl = request.URL;

    if ([newUrl isEqualTo:self.fileURL] || [newUrl isEqualTo:oldUrl])
    {
        // We are rendering ourselves.
        [listener use];
    }
    else
    {
        // An external location is requested. Hijack.
        [listener ignore];
        [[NSWorkspace sharedWorkspace] openURL:request.URL];
    }
}


#pragma mark - Notification handler

- (void)textDidChange:(NSNotification *)notification
{
    [self parseLaterWithCommand:@selector(parse) completionHandler:^{
        [self render];
    }];
}

- (void)userDefaultsDidChange:(NSNotification *)notification
{
    [self parseLaterWithCommand:@selector(parseIfPreferencesChanged)
              completionHandler:^{
                  [self render];
              }];
    [self renderIfPreferencesChanged];
    [self setupEditor];
}

- (void)boundsDidChange:(NSNotification *)notification
{
    [self syncScrollers];
}


#pragma mark - IBAction

- (IBAction)copyHtml:(id)sender
{
    // Dis-select things in WebView so that it's more obvious we're NOT
    // respecting the selection range.
    [self.preview setSelectedDOMRange:nil affinity:NSSelectionAffinityUpstream];

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard writeObjects:@[self.currentHtml]];
}

- (IBAction)exportHtml:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"html"];
    if (self.fileURL)
    {
        NSString *fileName = self.fileURL.lastPathComponent;
        if ([fileName hasSuffix:@".md"])
            fileName = [fileName substringToIndex:(fileName.length - 3)];
        panel.nameFieldStringValue = fileName;
    }

    MPExportPanelAccessoryViewController *controller =
        [[MPExportPanelAccessoryViewController alloc] initWithNibName:nil
                                                               bundle:nil];
    panel.accessoryView = controller.view;

    NSWindow *w = nil;
    NSArray *windowControllers = self.windowControllers;
    if (windowControllers.count)
        w = [windowControllers[0] window];
    [panel beginSheetModalForWindow:w completionHandler:^(NSInteger result) {
        if (result != NSFileHandlingPanelOKButton)
            return;

        NSMutableArray *filesToCopy = [NSMutableArray array];

        NSArray *styles = self.stylesheets;
        switch (controller.stylesheetOption)
        {
            case MPAssetsNone:
                styles = nil;
                break;
            case MPAssetsStripPath:
                [filesToCopy addObjectsFromArray:styles];
                break;
            case MPAssetsEmbedded:
                break;
            default:
                break;
        }
        NSArray *scripts = self.scripts;
        switch (controller.scriptOption)
        {
            case MPAssetsNone:
                scripts = nil;
                break;
            case MPAssetsStripPath:
                [filesToCopy addObjectsFromArray:scripts];
                break;
            case MPAssetsEmbedded:
                break;
            default:
                break;
        }
        NSString *html = [self htmlDocumentFromBody:self.currentHtml
                                        stylesheets:styles
                                           option:controller.stylesheetOption
                                            scripts:scripts
                                             option:controller.scriptOption];
        [html writeToURL:panel.URL atomically:NO encoding:NSUTF8StringEncoding
                   error:NULL];

        NSFileManager *manager = [NSFileManager defaultManager];
        for (NSString *path in filesToCopy)
        {
            NSURL *source = [NSURL fileURLWithPath:path];
            NSURL *target = [NSURL URLWithString:path.lastPathComponent
                                   relativeToURL:panel.directoryURL];
            [manager copyItemAtURL:source toURL:target error:NULL];
        }
    }];
}

- (IBAction)toggleStrong:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"**" suffix:@"**"];
}

- (IBAction)toggleEmphasis:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"*" suffix:@"*"];
}

- (IBAction)toggleInlineCode:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"`" suffix:@"`"];
}

- (IBAction)toggleStrikethrough:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"~~" suffix:@"~~"];
}

- (IBAction)toggleUnderline:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"_" suffix:@"_"];
}

- (IBAction)toggleHighlight:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"==" suffix:@"=="];
}

- (IBAction)toggleComment:(id)sender
{
    [self.editor toggleForMarkupPrefix:@"<!--" suffix:@"-->"];
}

- (IBAction)insertNewParagraph:(id)sender
{
    NSRange range = self.editor.selectedRange;
    NSUInteger location = range.location;
    NSUInteger length = range.length;
    NSString *content = self.editor.string;
    NSInteger newlineBefore = [content locationOfFirstNewlineBefore:location];
    NSUInteger newlineAfter =
        [content locationOfFirstNewlineAfter:location + length - 1];

    // This is an empty line. Treat as normal return key.
    if (location == newlineBefore + 1 && location == newlineAfter)
    {
        [self.editor insertNewline:self];
        return;
    }

    // Insert two newlines after the current line, and jump to there.
    self.editor.selectedRange = NSMakeRange(newlineAfter, 0);
    [self.editor insertText:@"\n\n"];
}


#pragma mark - Private

- (void)setupEditor
{
    self.editor.font = [self.preferences.editorBaseFont copy];

    CGFloat x = self.preferences.editorHorizontalInset;
    CGFloat y = self.preferences.editorVerticalInset;
    self.editor.textContainerInset = NSMakeSize(x, y);

    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = self.preferences.editorLineSpacing;
    self.editor.defaultParagraphStyle = [style copy];

    NSString *themeName = [self.preferences.editorStyleName copy];
    if (!themeName.length)
    {
        self.editor.textColor = nil;
        self.editor.backgroundColor = nil;
        self.highlighter.styles = nil;
        [self.highlighter readClearTextStylesFromTextView];
    }
    else
    {
        NSString *path = MPThemePathForName(themeName);
        NSString *themeString = MPReadFileOfPath(path);
        [self.highlighter applyStylesFromStylesheet:themeString
                                   withErrorHandler:
            ^(NSArray *errorMessages) {
                self.preferences.editorStyleName = nil;
            }];
    }

    // Have to keep this enabled because HGMarkdownHighlighter needs them.
    NSClipView *contentView = self.editor.enclosingScrollView.contentView;
    contentView.postsBoundsChangedNotifications = YES;
}

- (void)parseLaterWithCommand:(SEL)action completionHandler:(void(^)())handler
{
    [self.parseDelayTimer invalidate];
    self.parseDelayTimer =
        [NSTimer scheduledTimerWithTimeInterval:0.5
                                         target:self
                                       selector:action
                                       userInfo:@{@"next": handler}
                                        repeats:YES];
}

- (void)syncScrollers
{
    if (!self.preferences.editorSyncScrolling)
        return;

    NSScrollView *editorScrollView = self.editor.enclosingScrollView;
    NSClipView *editorContentView = editorScrollView.contentView;
    NSView *editorDocumentView = editorScrollView.documentView;
    NSRect editorContentBounds = editorContentView.bounds;
    CGFloat ratio =
        editorContentBounds.origin.y / (editorDocumentView.frame.size.height
                                        - editorContentBounds.size.height);

    NSScrollView *previewScrollView =
        self.preview.mainFrame.frameView.documentView.enclosingScrollView;
    NSClipView *previewContentView = previewScrollView.contentView;
    NSView *previewDocumentView = previewScrollView.documentView;
    NSRect previewContentBounds = previewContentView.bounds;
    previewContentBounds.origin.y =
        ratio * (previewDocumentView.frame.size.height
                 - previewContentBounds.size.height);
    previewContentView.bounds = previewContentBounds;
}

- (void)parse
{
    void(^nextAction)() = self.parseDelayTimer.userInfo[@"next"];
    [self.parseDelayTimer invalidate];

    int flags = self.preferences.extensionFlags;
    BOOL smartyPants = self.preferences.extensionSmartyPants;

    NSString *source = self.editor.string;
    self.currentHtml = [self htmlFromText:source
                          withSmartyPants:smartyPants flags:flags];

    // Record current parsing flags for -parseIfPreferencesChanged.
    self.currentExtensionFlags = flags;
    self.currentSmartyPantsFlag = smartyPants;

    if (nextAction)
        nextAction();
}

- (void)parseIfPreferencesChanged
{
    if (self.preferences.extensionFlags != self.currentExtensionFlags
        | self.preferences.extensionSmartyPants != self.currentSmartyPantsFlag)
    {
        [self parse];
    }
}

- (void)render
{
    NSString *styleName = self.preferences.htmlStyleName;
    NSString *html = [self htmlDocumentFromBody:self.currentHtml
                                    stylesheets:self.stylesheets
                                         option:MPAssetsFullLink
                                        scripts:self.scripts
                                         option:MPAssetsFullLink];
    NSURL *baseUrl = self.fileURL;
    if (!baseUrl)
        baseUrl = self.preferences.htmlDefaultDirectoryUrl;
    [self.preview.mainFrame loadHTMLString:html baseURL:baseUrl];

    // Record current rendering flags for -renderIfPreferencesChanged.
    self.currentStyleName = styleName;
    self.currentSyntaxHighlighting = self.preferences.htmlSyntaxHighlighting;
}

- (void)renderIfPreferencesChanged
{
    if (self.preferences.htmlStyleName != self.currentStyleName
        || (self.preferences.htmlSyntaxHighlighting
            != self.currentSyntaxHighlighting))
        [self render];
}

- (NSString *)htmlFromText:(NSString *)text
           withSmartyPants:(BOOL)smartyPantsEnabled flags:(int)flags
{
    NSData *inputData = [text dataUsingEncoding:NSUTF8StringEncoding];

    hoedown_markdown *markdown =
        hoedown_markdown_new(flags, 15, self.htmlRenderer);

    hoedown_buffer *ib = hoedown_buffer_new(64);
    hoedown_buffer *ob = hoedown_buffer_new(64);

    const uint8_t *data = 0;
    size_t size = 0;
    if (smartyPantsEnabled)
    {
        hoedown_html_smartypants(ib, inputData.bytes, inputData.length);
        data = ib->data;
        size = ib->size;
    }
    else
    {
        data = inputData.bytes;
        size = inputData.length;
    }
    hoedown_markdown_render(ob, data, size, markdown);

    NSString *result = [NSString stringWithUTF8String:hoedown_buffer_cstr(ob)];

    hoedown_markdown_free(markdown);
    hoedown_buffer_free(ib);
    hoedown_buffer_free(ob);

    return result;
}

- (NSString *)htmlDocumentFromBody:(NSString *)body
                       stylesheets:(NSArray *)stylesheetPaths
                            option:(MPAssetsOption)stylesOption
                           scripts:(NSArray *)scriptPaths
                            option:(MPAssetsOption)scriptsOption
{
    NSString *format;

    NSString *title = @"";
    if (self.fileURL)
    {
        title = self.fileURL.lastPathComponent;
        if ([title hasSuffix:@".md"])
            title = [title substringToIndex:title.length - 3];
        title = [NSString stringWithFormat:@"<title>%@</title>\n", title];
    }

    // Styles.
    NSMutableArray *styles =
        [NSMutableArray arrayWithCapacity:stylesheetPaths.count];
    format = @"<link rel=\"stylesheet\" type=\"text/css\" href=\"%@\">";
    for (NSString *path in stylesheetPaths)
    {
        NSString *s = nil;
        switch (stylesOption)
        {
            case MPAssetsFullLink:
                s = [NSString stringWithFormat:
                        format, [[NSURL fileURLWithPath:path] absoluteString]];
                break;
            case MPAssetsStripPath:
                s = [NSString stringWithFormat:format, path.lastPathComponent];
                break;
            case MPAssetsEmbedded:
                s = MPReadFileOfPath(path);
                break;
            default:
                break;
        }
        if (s)
            [styles addObject:s];
    }
    NSString *style = [styles componentsJoinedByString:@"\n"];
    if (stylesOption == MPAssetsEmbedded)
        style = [NSString stringWithFormat:@"<style>\n%@</style>", style];

    // Scripts.
    NSMutableArray *scripts =
        [NSMutableArray arrayWithCapacity:scriptPaths.count];
    format = @"<script type=\"text/javascript\" src=\"%@\"></script>";
    for (NSString *path in scriptPaths)
    {
        NSString *s = nil;
        switch (scriptsOption)
        {
            case MPAssetsFullLink:
                s = [NSString stringWithFormat:
                        format, [[NSURL fileURLWithPath:path] absoluteString]];
                break;
            case MPAssetsStripPath:
                s = [NSString stringWithFormat:format, path.lastPathComponent];
                break;
            case MPAssetsEmbedded:
                s = MPReadFileOfPath(path);
                break;
            default:
                break;
        }
        if (s)
            [scripts addObject:s];
    }
    NSString *script = [scripts componentsJoinedByString:@"\n"];
    if (scriptsOption == MPAssetsEmbedded)
        script = [NSString stringWithFormat:@"<script>%@</script>", script];

    static NSString *f =
        (@"<!DOCTYPE html><html>\n\n"
         @"<head>\n<meta charset=\"utf-8\">\n%@%@\n"
         @"<body>\n%@\n%@\n</body>\n\n</html>\n");

    NSString *html = [NSString stringWithFormat:f, title, style, body, script];
    return html;
}

@end