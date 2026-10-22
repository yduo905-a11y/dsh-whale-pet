# images —— 所有图片素材都在这

桌宠用到的**成品图（640×640 透明底）**和**原图（你发来的 1254×1254 原稿）**都放在这个目录，插件只从这里取图。
`raw\` 里是历史原稿存档（早期参考图 / 没做成成品图的版本），不参与运行，纯备份。

## 成品图 ↔ 原图 对照

| 成品（运行使用） | 原图（重新处理用） | 是什么 |
| --- | --- | --- |
| `mascot.png` | `mascot-src.png` | 常态立绘（面无表情吐槽那张） |
| `mascot-pat.png` | `mascot-pat-src.png` | 摸头 · 常态/绿（眯眼笑＋爱心，小猫粘人） |
| `mascot-pat-warn.png` | `mascot-pat-warn-src.png` | 摸头 · 黄档（可怜兮兮求你） |
| `mascot-pat-danger.png` | `mascot-pat-danger-src.png` | 摸头 · 红档（不爽冒烟，快没电） |
| `mascot-warn.png` | `mascot-warn-src.png` | 余额黄档底色 |
| `mascot-danger.png` | `mascot-danger-src.png` | 余额红档底色 |
| `mascot-eat1.png` | `mascot-eat1-src.png` | 吃饭 · 咀嚼（连击时和图二交替） |
| `mascot-eat2.png` | `mascot-eat2-src.png` | 吃饭 · 扒饭塞嘴 |
| `mascot-eat3.png` | `mascot-eat3-src.png` | 吃饱 · 打嗝收尾 |
| `mascot-choke1.png` | `mascot-choke1-src.png` | 呛到 · 噎住（满脸通红） |
| `mascot-choke2.png` | `mascot-choke2-src.png` | 呛到 · 咳出来 |
| `mascot.xaml` | — | 内置矢量鲸娘（没有 `mascot.png` 时的兜底） |

## 命名规矩（想加新表情就按这个来）

`mascot-<动作>-<状态>.png`，状态 `warn`（黄）/ `danger`（红）不写就是常态版。
比如你画了「红着脸吃饭」→ 命名 `mascot-eat1-danger.png` 丢进来，**不用改代码**就生效；
查表顺序是 `<动作>-<状态>` → `<动作>` → `mascot.png`（缺哪张就退回哪张）。

## 重新处理原图（抠底 / 裁切 / 缩到 640）

```bat
powershell -STA -File tools\make-mascot.ps1                                     :: 默认处理 mascot-src.png -> mascot.png
powershell -STA -File tools\make-mascot.ps1 -Src images\mascot-eat2-src.png -Dst images\mascot-eat2.png
```

> 批量成品的统一做法：所有立绘用**同一个裁切框**（源图坐标 `(62,44) 1192×1210`）再补成 640×640 正方形，
> 这样切换表情时脑袋不会跳位。`raw\` 里的原稿都是留着做这个的。

## raw\ 里都存了什么

历史原稿，文件名是 `日期_原剪贴板 id`，按大小可以认出来：

| 文件 | 尺寸 | 大概是什么 |
| --- | --- | --- |
| `0926-0202` / `0926-0215` / `0926-0236` | 1254×1254 | 摸头立绘的早期版本（抠图前后的几稿） |
| `0928-1959` | 1254×1254 | 呛到立绘的早期版本（正式稿是 20:13 那两张） |
| `0925-2240` / `0925-2305` / `0925-2328` | 744×861 | 气泡框设计稿 |
| `0926-0014` | 1346×1168 | 气泡框 / 挂件位置参考 |
| `0926-0031` / `0926-0047` / `0926-0048` / `0926-0114` | 279×336 等 | 挂件与气泡相对位置的截图参考 |

> 只保留和 dsh-overlay 有关的稿；之前误收进来的其它项目截图已清掉（要找回：`git show 30a797e:images/raw/<文件名> > <目标路径>`）。