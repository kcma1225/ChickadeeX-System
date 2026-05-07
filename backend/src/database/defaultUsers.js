const { getDB } = require('./connection');
const { logger } = require('../utils/logger');

const defaultUsers = [
    {
        email: 'admin@chickadeex.com',
        name: 'System Administrator',
        role: 'admin',
        localPassword: '$2a$10$Xsm39BDwmOWjSubIbymq9ubHfzMNsaDFzCtvyFmYcPvTRlEi6y5Pm'
    },
    {
        email: 'doctor@chickadeex.com',
        name: 'Doctor',
        role: 'doctor',
        localPassword: '$2a$10$kCdzSc19xNRT4ATk1bVWWO0B1VP5fpaf.CWqZeka6fQ4irpbqf0bO'
    },
    {
        email: 'user@chickadeex.com',
        name: 'Test User',
        role: 'observer',
        localPassword: '$2a$10$zCgKAdlv12kP0/cDGGoRt.XyricrN2Nown5NITTU7L1237uASEUcm'
    }
];

const seedDefaultUsers = async () => {
    const db = getDB();

    const query = `
        INSERT INTO users (email, name, role_id, local_password, is_active)
        SELECT $1, $2, r.id, $3, true
        FROM roles r
        WHERE r.name = $4
        ON CONFLICT (email) DO NOTHING
        RETURNING email
    `;

    let created = 0;

    for (const user of defaultUsers) {
        const result = await db.query(query, [
            user.email,
            user.name,
            user.localPassword,
            user.role
        ]);

        created += result.rowCount;
    }

    if (created > 0) {
        logger.info(`Seeded ${created} default local user(s)`);
    }
};

module.exports = {
    seedDefaultUsers
};
