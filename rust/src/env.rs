//! The environment: build the children, wire them, get out of the way.
//!
//! The tree mirrors the SystemVerilog environment — agent, monitors,
//! scoreboard — so a failure in one is legible in the other.
//!
//! ```text
//!   MemoryAgent  --> DUT instruction/data ports
//!   RetireMonitor --> [retire_q] --> Scoreboard --> golden vectors
//! ```

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
