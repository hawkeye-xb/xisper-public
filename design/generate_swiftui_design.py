#!/usr/bin/env python3
"""生成完整的 SwiftUI 设计系统 Pencil 文件"""

import json

# 基础设计系统变量 (基于 DesignTokens.swift)
design = {
    "version": "2.8",
    "variables": {
        # Primary colors (Teal/Cyan from DesignTokens.swift)
        "color-primary": {"type": "color", "value": "#008F9F"},      # primary8
        "color-primary-hover": {"type": "color", "value": "#007C8B"}, # primary9
        "color-primary-light": {"type": "color", "value": "#F8FCFD"}, # primary1
        
        # Text colors (Neutral scale)
        "color-text-primary": {"type": "color", "value": "#1E1F20"},  # neutral12
        "color-text-secondary": {"type": "color", "value": "#696D6D"}, # neutral9
        "color-text-tertiary": {"type": "color", "value": "#9C9FA0"},  # neutral7
        
        # Background colors
        "color-bg-canvas": {"type": "color", "value": "#FBFBFB"},     # neutral1
        "color-bg-card": {"type": "color", "value": "#F5F5F5"},       # neutral2
        "color-bg-hover": {"type": "color", "value": "#E9E9EA"},      # neutral3
        
        # Semantic colors
        "color-success": {"type": "color", "value": "#3E9245"},       # success8
        "color-warning": {"type": "color", "value": "#BE6000"},       # warning8
        "color-danger": {"type": "color", "value": "#CB4E4A"},        # danger8
        "color-info": {"type": "color", "value": "#008EA9"},          # info8
        
        "color-success-light": {"type": "color", "value": "#F9FCF9"}, # success1
        "color-danger-light": {"type": "color", "value": "#FFFAF9"},  # danger1
        "color-info-light": {"type": "color", "value": "#F8FCFD"},    # info1
        
        # Typography
        "font-system": {"type": "string", "value": "SF Pro Text"},
        "font-display": {"type": "string", "value": "SF Pro Display"},
        "font-mono": {"type": "string", "value": "SF Mono"},
        
        # Border radius (from DesignRadius)
        "radius-xs": {"type": "number", "value": 2},
        "radius-sm": {"type": "number", "value": 6},
        "radius-md": {"type": "number", "value": 10},
        "radius-lg": {"type": "number", "value": 16},
        "radius-xl": {"type": "number", "value": 20},
        "radius-full": {"type": "number", "value": 9999},
        
        # Spacing (from DesignSpacing)
        "spacing-xs": {"type": "number", "value": 8},
        "spacing-sm": {"type": "number", "value": 16},
        "spacing-md": {"type": "number", "value": 24},
        "spacing-lg": {"type": "number", "value": 32},
        "spacing-xl": {"type": "number", "value": 48}
    },
    "children": []
}

print("✅ 设计系统变量已创建")
print(f"   - {len(design['variables'])} 个 Design Tokens")
print(f"   - 基于 DesignTokens.swift 配色方案")

# 保存基础文件
with open('xisper-swiftui-complete.pen', 'w') as f:
    json.dump(design, f, indent=2)

print("\n💾 基础文件已保存: xisper-swiftui-complete.pen")
