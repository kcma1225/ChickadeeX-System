const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const compression = require('compression');
require('dotenv').config();

const { logger } = require('./utils/logger');
const { connectDB, closeDB } = require('./database/connection');
const { connectRedis, closeRedis } = require('./database/redis');
const { seedDefaultUsers } = require('./database/defaultUsers');
const errorHandler = require('./middleware/errorHandler');
const createSessionConfig = require('./middleware/sessionConfig');

// Import routes
const authRoutes = require('./routes/auth');
const userRoutes = require('./routes/users');
const reportRoutes = require('./routes/reports');
const adminRoutes = require('./routes/admin');
const llmRoutes = require('./routes/llm');
const auditRoutes = require('./routes/audit');
const dicomRoutes = require('./routes/dicom');
const uploadRoutes = require('./routes/uploads');

const app = express();
const PORT = process.env.PORT || 3000;
let server;
const sockets = new Set();

app.set('trust proxy', 1);


// Middleware
app.use(helmet({
    contentSecurityPolicy: {
        directives: {
            defaultSrc: ["'self'"],
            styleSrc: ["'self'", "'unsafe-inline'"],
            scriptSrc: ["'self'"],
            imgSrc: ["'self'", "data:", "https:"],
        }
    }
}));

app.use(compression());

// CORS configuration
app.use(cors({
    origin: process.env.CORS_ORIGIN || 'http://localhost:3001',
    credentials: true,
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Requested-With', 'Cookie']
}));

app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true, limit: '10mb' }));

// Simple cookie parsing without external dependency
app.use((req, res, next) => {
    const cookieHeader = req.headers.cookie;
    req.cookies = {};
    if (cookieHeader) {
        cookieHeader.split(';').forEach(cookie => {
            const [name, value] = cookie.trim().split('=');
            if (name && value) {
                req.cookies[name] = decodeURIComponent(value);
            }
        });
    }
    next();
});

app.use((req, res, next) => {
    if (['POST', 'PUT', 'DELETE'].includes(req.method)) {
        const requestedWith = req.get('X-Requested-With');
        if (requestedWith !== 'XMLHttpRequest') {
            return res.status(400).json({ error: 'Missing or invalid X-Requested-With header' });
        }
    }
    next();
});

// Session configuration will be added after Redis connection

// Health check endpoint
app.get('/health', (req, res) => {
    res.status(200).json({ 
        status: 'healthy',
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        memory: process.memoryUsage()
    });
});

// API routes
// Rate limiting disabled per configuration request
app.use('/api/auth', authRoutes);
app.use('/api/users', userRoutes);
app.use('/api/reports', reportRoutes);
app.use('/api/admin', adminRoutes);
app.use('/api/llm', llmRoutes);
app.use('/api/audit', auditRoutes);
app.use('/api/dicom', dicomRoutes);
app.use('/api/uploads', uploadRoutes);
app.use('/api/demo', uploadRoutes);

// 404 handler
app.use('*', (req, res) => {
    res.status(404).json({ 
        error: 'Not Found',
        message: `Route ${req.originalUrl} not found`
    });
});

// Error handling middleware
app.use(errorHandler);

const shutdown = async (signal) => {
    logger.info(`${signal} received, shutting down gracefully`);

    const shutdownTimer = setTimeout(() => {
        logger.error('Forced shutdown after timeout');
        process.exit(1);
    }, 10000);

    shutdownTimer.unref();

    if (server) {
        server.close(() => {
            logger.info('HTTP server closed');
        });
        for (const socket of sockets) {
            socket.destroy();
        }
    }

    try {
        await closeRedis();
    } catch (error) {
        logger.warn('Failed to close Redis gracefully', error);
    }

    try {
        await closeDB();
    } catch (error) {
        logger.warn('Failed to close database gracefully', error);
    }

    process.exit(0);
};

// Start server
async function startServer() {
    try {
        // Connect to database
        await connectDB();
        logger.info('Database connected successfully');

        await seedDefaultUsers();
        
        // Connect to Redis
        await connectRedis();
        logger.info('Redis connected successfully');
        
        // Configure session after Redis is connected
        app.use(createSessionConfig());
        
        // Start HTTP server
        server = app.listen(PORT, '0.0.0.0', () => {
            logger.info(`Server running on port ${PORT}`);
            logger.info(`Environment: ${process.env.NODE_ENV}`);
            logger.info(`CORS Origin: ${process.env.CORS_ORIGIN}`);
        });

        server.on('connection', (socket) => {
            sockets.add(socket);
            socket.on('close', () => sockets.delete(socket));
        });
    } catch (error) {
        logger.error('Failed to start server:', error);
        process.exit(1);
    }
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

startServer();

module.exports = app;
