# 一个web思维导图的简单实现

详细文档见：[https://github.com/wanglin2/mind-map](https://github.com/wanglin2/mind-map)

# 打包项目
1. 更新版本号: npm version patch
2. 本地安装vite: npm install vite@4.5.3 --save-dev（vite@4 是最后一个支持 Node 16 的版本。）
3. 用npx临时执行打包命令： npx vite build（全局安装vite可以用vite build）
4. 验证打包结果： 查看dist目录中是否包含index.umd.js和index.es.js文件
5. 把npm源设置为npm官方源： npm config set registry https://registry.npmjs.org/
6. 执行发布npm命令：npm publish

# 拉取上游仓库更新
1. 添加上游仓库： git remote add upstream https://github.com/wanglin2/mind-map.git
2. 拉取上游仓库： git pull upstream main