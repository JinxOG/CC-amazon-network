// What the sandbox map draws, built from a /state document. Used by the page (inlined by fileserver.js) and by the test.
(function (root, factory) {
    if (typeof module === 'object' && module.exports) module.exports = factory();
    else root.buildMapModel = factory().buildMapModel;
})(typeof self !== 'undefined' ? self : this, function () {
    const ROLE_COLOUR = { MINER: '#ff9f43', DELIVERY: '#4dabf7', SUPPORT: '#69db7c', LOADER: '#da77f2', WAREHOUSE: '#ffd43b' };
    const SECTOR = 32;

    function zoneCells(zone, turtles) {
        const b = zone.rawBounds || zone.bounds;
        if (!b) return [];
        const cells = [];
        for (let z = b.z1; z < b.z2; z += SECTOR) {
            for (let x = b.x1; x < b.x2; x += SECTOR) cells.push({ x1: x, z1: z, x2: Math.min(x + SECTOR, b.x2), z2: Math.min(z + SECTOR, b.z2), state: 'pending' });
        }
        // The state carries counts, not a per-sector list: the first N cells (grid order) are shown as done,
        // and the cell a working miner stands in as assigned. The shading is approximate.
        const n = zone.phase === 'SURVEY' ? (zone.surveyDone || 0) : (zone.done || 0);
        for (let i = 0; i < Math.min(n, cells.length); i++) cells[i].state = 'done';
        for (const t of turtles) {
            if (t.role !== 'MINER' || typeof t.x !== 'number') continue;
            for (const c of cells) {
                if (t.x >= c.x1 - 16 && t.x < c.x2 + 16 && t.z >= c.z1 - 16 && t.z < c.z2 + 16 && c.state !== 'done') { c.state = 'assigned'; break; }
            }
        }
        return cells;
    }

    function buildMapModel(state) {
        state = state || {};
        const turtles = [];
        for (const [id, t] of Object.entries(state.turtles || {})) {
            if (typeof t.x !== 'number' || typeof t.z !== 'number') continue;
            turtles.push({ id, x: t.x, y: t.y, z: t.z, role: (t.role || '?').toUpperCase(), status: t.status || '', online: t.online !== false,
                colour: ROLE_COLOUR[(t.role || '').toUpperCase()] || '#adb5bd' });
        }
        const zones = Object.entries(state.mineZones || {}).map(([jobId, z]) => ({
            jobId, bounds: z.rawBounds || z.bounds, phase: z.phase, cells: zoneCells(z, turtles),
        })).filter((z) => z.bounds);
        return { turtles, zones, depot: { x1: 130, z1: -2815, x2: 235, z2: -2780 }, note: 'Sandbox map - simulated world, not Dynmap' };
    }
    return { buildMapModel, ROLE_COLOUR };
});
