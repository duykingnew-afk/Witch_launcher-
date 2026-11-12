#import <UIKit/UIKit.h>
#import "ThemeManager.h"

// Hình dạng và màu kiểu Zalith 2, dùng chung cho các màn hình. Theo source
// Zalith: card ngoài bo 28, icon bo 28% cạnh, ô nhập bo 16, nút tonal dạng viên.
static inline CGFloat ZalithCardRadius(void) { return 28.0; }
static inline CGFloat ZalithFieldRadius(void) { return 16.0; }
static inline CGFloat ZalithIconRadius(CGFloat side) { return side * 0.28; }

// Nút tonal (secondaryContainer của Zalith), xấp xỉ bằng accent nhạt.
static inline UIColor *ZalithTonalColor(void) {
    return [ThemeManager.shared.accentColor colorWithAlphaComponent:0.16];
}

// Ô tìm kiếm của UISearchBar: nền card, bo 16.
static inline void ZalithStyleSearchBar(UISearchBar *bar) {
    UITextField *field = bar.searchTextField;
    field.backgroundColor = ThemeManager.shared.cardBackgroundColor;
    field.layer.cornerRadius = ZalithFieldRadius();
    field.clipsToBounds = YES;
}
