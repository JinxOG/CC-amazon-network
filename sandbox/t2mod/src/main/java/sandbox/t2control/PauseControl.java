package sandbox.t2control;

/**
 * Pause and step (spec section 6): while paused the server does not run game ticks at all (no world, no computers, no timers); each
 * step lets a given number of ticks run and then pauses again. Commands from the console still work while paused. Pure logic (no
 * Minecraft types) so it can be unit tested; the server-tick hook asks {@link #shouldRun} once per tick.
 */
public final class PauseControl {
    public static final PauseControl INSTANCE = new PauseControl();

    private boolean paused;
    private long steps;
    private long ticksRun;
    private long ticksHeld;

    public synchronized void pause() { paused = true; }

    /** Resumes normal running and forgets any steps still owed. */
    public synchronized void resume() {
        paused = false;
        steps = 0;
    }

    /** Lets {@code n} more ticks run. Pauses first if the server was running (a step from a running server means "pause after n ticks"). */
    public synchronized void step(long n) {
        paused = true;
        steps += Math.max(0, n);
    }

    public synchronized boolean isPaused() { return paused; }

    public synchronized long stepsLeft() { return steps; }

    public synchronized long ticksHeld() { return ticksHeld; }

    /** True when this tick should run. */
    public synchronized boolean shouldRun() {
        if (!paused) return true;
        if (steps > 0) {
            steps--;
            ticksRun++;
            return true;
        }
        ticksHeld++;
        return false;
    }

    public synchronized long stepsRun() { return ticksRun; }
}
