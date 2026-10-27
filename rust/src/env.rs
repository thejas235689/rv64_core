//! The environment: build the children, wire them, get out of the way.

use rustdv::prelude::*;

use crate::components::{MemoryAgent, RetireMonitor, Scoreboard};

#[derive(Component, Default)]
pub struct CoreEnv {
    #[component]
    agent: RustdvComp,
    #[component]
    monitor: RustdvComp,
    #[component]
    scoreboard: RustdvComp,
}

impl Component for CoreEnv {
    fn build(&mut self, _ctx: &mut RustdvCtx) {
        self.agent = MemoryAgent::new_comp();
        self.monitor = RetireMonitor::new_comp();
        self.scoreboard = Scoreboard::new_comp();
    }
}
