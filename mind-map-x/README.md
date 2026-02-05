# Web 版 XMind 思维导图（React + Vite）

使用 React 组件化重构的前端 MVP，支持基础的节点增删改、折叠，以及 JSON 导入导出。

## 快速开始
```bash
npm install
npm run dev   # 默认 http://127.0.0.1:4173
npm run build # 产物在 dist/
```

## 主要功能
- 点击选中节点，双击快速重命名。
- 添加子节点 / 同级节点、删除节点。
- 折叠 / 展开子树。
- 导出当前导图为 `mindmap.json`；从 JSON 文件导入并自动重新分配节点 ID。
- “重置示例”恢复内置 Demo。

## 技术栈
- React 18 + Vite 4（兼容 Node 16 环境）。
- 零第三方 UI 依赖，样式集中在 `styles.css`。

## 代码结构
- `src/App.jsx`：核心组件，包含数据结构、布局算法和交互逻辑。
- `src/main.jsx`：React 入口。
- `styles.css`：基础样式与节点卡片样式。
- `vite.config.js`：Vite 配置（固定 dev 端口 4173）。

## 布局与交互简述
- 横向树形布局：深度决定 X 坐标，子节点的平均 Y 作为父节点定位，避免重叠。
- 连接线使用 SVG 二次贝塞尔曲线。
- 节点状态（选中 / 折叠）用类名控制，渲染时一次性刷新节点与连线。

## 后续可拓展点
- 支持拖拽调序、键盘快捷键、迷你地图。
- 持久化到 localStorage。
- 导出图片 / PDF。
