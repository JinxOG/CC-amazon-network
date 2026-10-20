// What the sandbox map draws, built from a /state document. Used by the page (inlined by fileserver.js) and by the test.
(function (root, factory) {
    if (typeof module === 'object' && module.exports) module.exports = factory();
    else root.buildMapModel = factory().buildMapModel;
})(typeof self !== 'undefined' ? self : this, function () {
    const ROLE_COLOUR = { MINER: '#ff9f43', DELIVERY: '#4dabf7', SUPPORT: '#69db7c', LOADER: '#da77f2', WAREHOUSE: '#ffd43b' };
    const SECTOR = 32;

    // The sectors of a zone. rawBounds holds the sector CENTRES (x1..x2 and z1..z2 in steps of 32, both ends included);
    // a sector's footprint is its centre +/- 16. Without rawBounds the footprint rectangle is cut into 32 blocks.
    function zoneCells(zone, turtles) {
        const cells = [];
        const r = zone.rawBounds;
        if (r && typeof r.x1 === 'number') {
            for (let z = r.z1; z <= r.z2; z += SECTOR) {
                for (let x = r.x1; x <= r.x2; x += SECTOR) cells.push({ x1: x - 16, z1: z - 16, x2: x + 16, z2: z + 16, state: 'pending' });
            }
        } else {
            const b = zone.bounds;
            if (!b) return [];
            for (let z = b.z1; z < b.z2; z += SECTOR) {
                for (let x = b.x1; x < b.x2; x += SECTOR) cells.push({ x1: x, z1: z, x2: Math.min(x + SECTOR, b.x2), z2: Math.min(z + SECTOR, b.z2), state: 'pending' });
            }
        }
        // The state carries counts, not a per-sector list: the first N cells (grid order) are shown as done, and the
        // cell a working miner stands in as working. The shading is approximate.
        const n = zone.phase === 'SURVEY' ? (zone.surveyDone || 0) : (zone.done || 0);
        for (let i = 0; i < Math.min(n, cells.length); i++) cells[i].state = 'done';
        for (const t of turtles) {
            if (t.role !== 'MINER' || typeof t.x !== 'number') continue;
            for (const c of cells) {
                if (t.x >= c.x1 && t.x < c.x2 && t.z >= c.z1 && t.z < c.z2 && c.state !== 'done') { c.state = 'assigned'; break; }
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
        const jobs = Array.isArray(state.jobs) ? state.jobs : Object.values(state.jobs || {});
        const zones = Object.entries(state.mineZones || {}).map(([jobId, z]) => {
            const b = z.bounds;
            const key = b ? [b.x1, b.z1, b.x2, b.z2].join(',') : null;
            const miners = new Set();
            if (z.minerId) miners.add(z.minerId);
            for (const j of jobs) if (j && j.assignedTo && (j.id === jobId || (key && j.zoneKey === key))) miners.add(j.assignedTo);
            return { jobId, bounds: b, phase: z.phase, active: z.status === 'ACTIVE', minerIds: Array.from(miners), cells: zoneCells(z, turtles) };
        }).filter((z) => z.bounds);
        return { turtles, zones, depot: { x1: 130, z1: -2815, x2: 235, z2: -2780 }, note: 'Sandbox map - simulated world, not Dynmap' };
    }
    return { buildMapModel, ROLE_COLOUR };
});
