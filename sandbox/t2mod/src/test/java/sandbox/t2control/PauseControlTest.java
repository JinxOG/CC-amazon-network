package sandbox.t2control;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

class PauseControlTest {
    @Test
    void runsEveryTickUntilPaused() {
        PauseControl p = new PauseControl();
        for (int i = 0; i < 20; i++) assertTrue(p.shouldRun());
    }

    @Test
    void whilePausedNoTickRunsAndEachHeldTickIsCounted() {
        PauseControl p = new PauseControl();
        p.pause();
        for (int i = 0; i < 7; i++) assertFalse(p.shouldRun());
        assertEquals(7, p.ticksHeld());
        assertTrue(p.isPaused());
    }

    @Test
    void aStepRunsExactlyThatManyTicksThenPausesAgain() {
        PauseControl p = new PauseControl();
        p.pause();
        p.step(10);
        int ran = 0;
        for (int i = 0; i < 50; i++) if (p.shouldRun()) ran++;
        assertEquals(10, ran);
        assertEquals(10, p.stepsRun());
        assertEquals(0, p.stepsLeft());
        assertFalse(p.shouldRun());
    }

    @Test
    void stepsAddUpAndAStepFromARunningServerMeansPauseAfterThose() {
        PauseControl p = new PauseControl();
        p.step(3);
        p.step(2);
        assertEquals(5, p.stepsLeft());
        assertTrue(p.isPaused());
    }

    @Test
    void resumeRunsAgainAndForgetsOwedSteps() {
        PauseControl p = new PauseControl();
        p.pause();
        p.step(100);
        p.resume();
        assertEquals(0, p.stepsLeft());
        for (int i = 0; i < 5; i++) assertTrue(p.shouldRun());
        assertFalse(p.isPaused());
    }
}
