# 一个web思维导图的简单实现

详细文档见：[https://github.com/wanglin2/mind-map](https://github.com/wanglin2/mind-map)

# 打包项目
1. 本地安装vite: npm install vite@4.5.3 --save-dev（vite@4 是最后一个支持 Node 16 的版本。）
2. 用npx临时执行打包命令： npx vite build（全局安装vite可以用vite build）
3. 验证打包结果： 查看dist目录中是否包含index.umd.js和index.es.js文件
4. 执行发布npm命令：npm publish