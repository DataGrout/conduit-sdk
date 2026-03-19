//! Sub-namespaces for domain-specific DataGrout tool families.
//!
//! Access via the accessor methods on [`Client`](crate::Client):
//!
//! ```rust,ignore
//! client.prism().refract("normalise addresses", payload).execute().await?;
//! client.logic().remember("user prefers metric units").await?;
//! client.warden().canary(json!({"action": "delete"})).await?;
//! client.flow().into(plan).execute().await?;
//! ```

mod deliverables;
mod ephemerals;
mod flow;
mod logic;
mod prism;
mod warden;

pub use deliverables::Deliverables;
pub use ephemerals::Ephemerals;
pub use flow::Flow;
pub use logic::Logic;
pub use prism::Prism;
pub use warden::Warden;
