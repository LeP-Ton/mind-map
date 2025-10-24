export default {
    build: {
      lib: {
        entry: 'index.js',
        name: 'LeoMindMap',
        fileName: (format) => `index.${format}.js`,
      },
      rollupOptions: {
        external: ['@svgdotjs/svg.js'],
      },
    },
  }
  