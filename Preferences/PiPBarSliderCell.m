//
//  PiPBarSliderCell.m
//  自绘实时数值标签（v0.7）：roothide 下私有 PSSliderCell 不渲染当前值文本，
//  且 setPreferenceValue: 在拖动中每帧触发，用 reload 刷新标题会打断手势。
//  故在单元格右上角叠加 UILabel，直接监听滑块 valueChanged 更新，零 reload。
//

#import "PiPBarSliderCell.h"
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>

// 本 theos SDK 的 Preferences 私有框架不含 PSSliderCell.h，前向声明 + 类别补齐所需方法，
// 既让子类化通过编译，也避免 import 缺失头触发 fatal error（-Werror）。
@class PSSliderCell;
@interface PSSliderCell (PIPInit)
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)ri
                    specifier:(PSSpecifier *)spec;
- (float)value;
@end

@implementation PiPBarSliderCell {
    UILabel *_pipVal;
    BOOL _pipWired;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)ri
                    specifier:(PSSpecifier *)spec {
    self = [super initWithStyle:style reuseIdentifier:ri specifier:spec];
    if (self) {
        _pipVal = [[UILabel alloc] initWithFrame:CGRectZero];
        _pipVal.font = [UIFont systemFontOfSize:13.0];
        _pipVal.textColor = [UIColor grayColor];
        _pipVal.textAlignment = NSTextAlignmentRight;
        _pipVal.backgroundColor = UIColor.clearColor;
        [self.contentView addSubview:_pipVal];
    }
    return self;
}

// 在子视图里找 UISlider（不依赖私有 ivar 名 _slider，跨版本稳健）
- (UISlider *)pipFindSlider {
    for (UIView *v in self.subviews) {
        if ([v isKindOfClass:[UISlider class]]) return (UISlider *)v;
        for (UIView *v2 in v.subviews) {
            if ([v2 isKindOfClass:[UISlider class]]) return (UISlider *)v2;
        }
    }
    return nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UISlider *sl = [self pipFindSlider];
    if (sl != nil && !_pipWired) {
        _pipWired = YES;
        [sl addTarget:self action:@selector(pipSliderChanged:)
            forControlEvents:UIControlEventValueChanged];
    }
    [self pipUpdateLabel];
    // 定位：标题右侧，右上角
    [_pipVal sizeToFit];
    CGRect b = self.contentView.bounds;
    CGFloat w = CGRectGetWidth(_pipVal.frame);
    CGFloat h = CGRectGetHeight(_pipVal.frame) > 0 ? CGRectGetHeight(_pipVal.frame) : 18.0;
    _pipVal.frame = CGRectMake(CGRectGetWidth(b) - w - 16.0, 4.0, w, h);
}

- (void)pipSliderChanged:(UISlider *)sender {
    (void)sender;
    [self pipUpdateLabel];
}

- (void)pipUpdateLabel {
    float v = 0.0f;
    @try { v = [self value]; } @catch (NSException *e) { v = 0.0f; (void)e; }
    _pipVal.text = [NSString stringWithFormat:@"%.0f pt", (double)v];
    [_pipVal sizeToFit];
}

@end
