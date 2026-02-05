import { useLayoutEffect, useMemo, useRef, useState } from 'react';

const NODE_WIDTH = 170;
const NODE_HEIGHT = 70;
const H_GAP = 220;
const V_GAP = 30;

const demoTree = {
  title: '产品规划',
  children: [
    {
      title: '市场',
      children: [{ title: '竞品调研' }, { title: '用户访谈' }],
    },
    {
      title: '目标',
      children: [
        { title: '季度KPI' },
        { title: '核心北极星指标' },
        { title: '里程碑拆解' },
      ],
    },
    {
      title: '方案',
      children: [
        { title: '信息架构' },
        { title: '交互原型' },
        { title: '技术可行性评估' },
      ],
    },
    {
      title: '风险',
      children: [
        { title: '进度风险' },
        { title: '资源风险' },
        { title: '质量风险' },
      ],
    },
  ],
};

let idCounter = 0;
const uid = () => `n-${Date.now().toString(36)}-${idCounter++}`;

const withIds = (node) => ({
  id: uid(),
  title: node.title || '未命名',
  collapsed: Boolean(node.collapsed),
  children: (node.children || []).map(withIds),
});

const findParentId = (node, targetId, parentId = null) => {
  if (node.id === targetId) return parentId;
  for (const child of node.children) {
    const hit = findParentId(child, targetId, node.id);
    if (hit) return hit;
  }
  return null;
};

const findNode = (node, targetId) => {
  if (node.id === targetId) return node;
  for (const child of node.children) {
    const hit = findNode(child, targetId);
    if (hit) return hit;
  }
  return null;
};

const updateNode = (node, targetId, updater) => {
  if (node.id === targetId) {
    return updater(node);
  }
  return {
    ...node,
    children: node.children.map((child) =>
      updateNode(child, targetId, updater)
    ),
  };
};

const removeNodeById = (node, targetId) => ({
  ...node,
  children: node.children
    .filter((child) => child.id !== targetId)
    .map((child) => removeNodeById(child, targetId)),
});

const computeLayout = (root) => {
  let cursorY = 40;
  const positions = {};
  let maxX = 0;
  let maxY = 0;

  const dfs = (node, depth) => {
    let y;
    const x = depth * H_GAP + 40;

    if (!node.children.length || node.collapsed) {
      y = cursorY;
      cursorY += NODE_HEIGHT + V_GAP;
    } else {
      const childYs = node.children.map((child) => dfs(child, depth + 1));
      y = Math.round(childYs.reduce((a, b) => a + b, 0) / childYs.length);
    }

    positions[node.id] = { x, y };
    maxX = Math.max(maxX, x + NODE_WIDTH + 200);
    maxY = Math.max(maxY, y + NODE_HEIGHT + 200);
    return y;
  };

  dfs(root, 0);
  return {
    positions,
    width: Math.max(maxX, 1200),
    height: Math.max(maxY, 800),
  };
};

const visibleNodes = (node, positions, acc = []) => {
  acc.push({ node, pos: positions[node.id] });
  if (!node.collapsed) {
    node.children.forEach((child) => visibleNodes(child, positions, acc));
  }
  return acc;
};

const visibleLinks = (node, positions, acc = []) => {
  if (!node.collapsed) {
    node.children.forEach((child) => {
      acc.push({
        fromId: node.id,
        toId: child.id,
        from: positions[node.id],
        to: positions[child.id],
        key: `${node.id}-${child.id}`,
      });
      visibleLinks(child, positions, acc);
    });
  }
  return acc;
};

const countNodes = (node) =>
  1 + node.children.reduce((sum, child) => sum + countNodes(child), 0);

const downloadJson = (data, filename) => {
  const blob = new Blob([JSON.stringify(data, null, 2)], {
    type: 'application/json',
  });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
};

function App() {
  const [root, setRoot] = useState(() => withIds(demoTree));
  const [selectedId, setSelectedId] = useState(null);
  const fileInputRef = useRef(null);
  const [nodeSizes, setNodeSizes] = useState({});

  const layout = useMemo(() => computeLayout(root), [root]);
  const nodes = useMemo(
    () => visibleNodes(root, layout.positions, []),
    [root, layout.positions]
  );
  const links = useMemo(
    () => visibleLinks(root, layout.positions, []),
    [root, layout.positions]
  );
  const currentId = selectedId ?? root.id;
  const selectedNode = useMemo(
    () => findNode(root, currentId) ?? root,
    [root, currentId]
  );
  const totalCount = useMemo(() => countNodes(root), [root]);

  useLayoutEffect(() => {
    const elements = document.querySelectorAll('.node[data-node-id]');
    const next = {};
    elements.forEach((el) => {
      const id = el.dataset.nodeId;
      if (!id) return;
      const rect = el.getBoundingClientRect();
      next[id] = { width: Math.round(rect.width), height: Math.round(rect.height) };
    });

    setNodeSizes((prev) => {
      const prevKeys = Object.keys(prev);
      const nextKeys = Object.keys(next);
      if (prevKeys.length !== nextKeys.length) return next;
      for (const key of nextKeys) {
        const prevSize = prev[key];
        const nextSize = next[key];
        if (
          !prevSize ||
          prevSize.width !== nextSize.width ||
          prevSize.height !== nextSize.height
        ) {
          return next;
        }
      }
      return prev;
    });
  }, [nodes.length, root]);

  const getNodeSize = (id) => nodeSizes[id] ?? { width: NODE_WIDTH, height: NODE_HEIGHT };

  const addChild = () => {
    const newNode = { id: uid(), title: '新想法', collapsed: false, children: [] };
    setRoot((prev) =>
      updateNode(prev, currentId, (n) => ({
        ...n,
        collapsed: false,
        children: [...n.children, newNode],
      }))
    );
    setSelectedId(newNode.id);
  };

  const addSibling = () => {
    if (currentId === root.id) return;
    const parentId = findParentId(root, currentId, null);
    if (!parentId) return;
    const sibling = { id: uid(), title: '同级想法', collapsed: false, children: [] };
    setRoot((prev) =>
      updateNode(prev, parentId, (p) => ({
        ...p,
        children: [...p.children, sibling],
      }))
    );
    setSelectedId(sibling.id);
  };

  const deleteNode = () => {
    if (currentId === root.id) return;
    const parentId = findParentId(root, currentId, null);
    if (!parentId) return;
    setRoot((prev) => removeNodeById(prev, currentId));
    setSelectedId(parentId);
  };

  const toggleCollapse = () => {
    setRoot((prev) =>
      updateNode(prev, currentId, (n) => ({ ...n, collapsed: !n.collapsed }))
    );
  };

  const renameNode = (id = currentId) => {
    const target = findNode(root, id);
    const next = window.prompt('输入新标题', target?.title || '');
    if (!next || !next.trim()) return;
    setRoot((prev) =>
      updateNode(prev, id, (n) => ({ ...n, title: next.trim() }))
    );
    setSelectedId(id);
  };

  const exportJson = () => downloadJson(root, 'mindmap.json');

  const handleImport = async (e) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const text = await file.text();
    try {
      const parsed = JSON.parse(text);
      setRoot(withIds(parsed));
      setSelectedId(null);
    } catch (err) {
      window.alert(`JSON 格式错误: ${err.message}`);
    } finally {
      e.target.value = '';
    }
  };

  const resetDemo = () => {
    setRoot(withIds(demoTree));
    setSelectedId(null);
  };

  const onBoardClick = () => setSelectedId(null);

  return (
    <>
      <header className="toolbar">
        <div className="toolbar-brand">
          <div className="brand">
            <div className="brand-title">Mindmap Studio</div>
            <div className="brand-subtitle">结构化思考 · 产品规划画布</div>
          </div>
          <div className="status" role="status" aria-live="polite">
            <div className="status-item">
              <span className="status-label">选中</span>
              <span className="status-value">
                {selectedNode?.title || '根主题'}
              </span>
            </div>
            <div className="status-item">
              <span className="status-label">可见节点</span>
              <span className="status-value">
                {nodes.length}/{totalCount}
              </span>
            </div>
          </div>
        </div>
        <div className="toolbar-actions">
          <div className="action-group">
            <button className="btn primary" onClick={addChild}>
              添加子节点
            </button>
            <button
              className="btn"
              onClick={addSibling}
              disabled={currentId === root.id}
            >
              添加同级
            </button>
            <button
              className="btn danger"
              onClick={deleteNode}
              disabled={currentId === root.id}
            >
              删除
            </button>
            <button className="btn ghost" onClick={toggleCollapse}>
              折叠/展开
            </button>
            <button className="btn ghost" onClick={renameNode}>
              重命名
            </button>
          </div>
          <div className="action-group">
            <button className="btn" onClick={exportJson}>
              导出JSON
            </button>
            <label className="btn import-btn">
              <span>导入JSON</span>
              <input
                ref={fileInputRef}
                type="file"
                accept="application/json"
                onChange={handleImport}
              />
            </label>
            <button className="btn" onClick={resetDemo}>
              重置示例
            </button>
          </div>
        </div>
      </header>

      <main id="board" onClick={onBoardClick}>
        <svg
          id="links"
          aria-label="mind map links"
          width={layout.width}
          height={layout.height}
          style={{ width: layout.width, height: layout.height }}
        >
          {links.map(({ from, to, fromId, toId, key }) => {
            const fromSize = getNodeSize(fromId);
            const toSize = getNodeSize(toId);
            const offset = (to.x - (from.x + fromSize.width)) / 2;
            const x1 = from.x + fromSize.width;
            const y1 = from.y + fromSize.height / 2;
            const x2 = to.x;
            const y2 = to.y + toSize.height / 2;
            return (
              <path
                key={key}
                d={`M${x1},${y1} C${x1 + offset},${y1} ${x2 - offset},${y2} ${x2},${y2}`}
                stroke="var(--link-color)"
                strokeWidth="2.2"
                fill="none"
              />
            );
          })}
        </svg>

        <div
          id="nodes"
          aria-label="mind map nodes"
          style={{ width: layout.width, height: layout.height }}
        >
          {nodes.map(({ node, pos }) => (
            <div
              key={node.id}
              className={`node${currentId === node.id ? ' selected' : ''}${
                node.collapsed ? ' collapsed' : ''
              }${node.id === root.id ? ' root' : ''}`}
              style={{ left: pos.x, top: pos.y }}
              data-node-id={node.id}
              role="button"
              tabIndex={0}
              aria-pressed={currentId === node.id}
              onClick={(e) => {
                e.stopPropagation();
                setSelectedId(node.id);
              }}
              onDoubleClick={(e) => {
                e.stopPropagation();
                renameNode(node.id);
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault();
                  setSelectedId(node.id);
                }
                if (e.key === 'F2') {
                  e.preventDefault();
                  renameNode(node.id);
                }
              }}
            >
              <div className="title">{node.title}</div>
              <div className="meta">
                {node.children.length ? `${node.children.length} 子节点` : '叶子节点'}
              </div>
            </div>
          ))}
        </div>
      </main>

      <div className="hint">
        点击节点选中；双击节点快速重命名；空白处点击返回根；滚轮可滚动查看
      </div>
    </>
  );
}

export default App;
