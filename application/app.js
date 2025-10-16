const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy' });
});

app.get('/', (req, res) => {
  const response = {
    message: 'Hello from Blue-Green Deployment!',
    version: process.env.VERSION || '1.0.0',
    color: process.env.COLOR || 'blue',
    environment: process.env.NODE_ENV || 'development',
    timestamp: new Date().toISOString(),
    hostname: require('os').hostname()
  };
  
  res.json(response);
});

app.get('/info', (req, res) => {
  res.json({
    app: 'blue-green-demo',
    nodeVersion: process.version,
    uptime: process.uptime(),
    memory: process.memoryUsage()
  });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`🚀 Server is running on port ${PORT}`);
  console.log(`🎨 Color: ${process.env.COLOR || 'blue'}`);
  console.log(`📦 Version: ${process.env.VERSION || '1.0.0'}`);
});
