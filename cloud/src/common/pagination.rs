use serde::{Deserialize, Serialize};

/// Pagination request parameters extracted from query strings.
#[derive(Debug, Clone, Deserialize)]
pub struct PaginationParams {
    #[serde(default = "default_page")]
    pub page: u64,
    #[serde(default = "default_per_page")]
    pub per_page: u64,
}

fn default_page() -> u64 {
    1
}

fn default_per_page() -> u64 {
    20
}

impl PaginationParams {
    pub fn offset(&self) -> u64 {
        (self.page.saturating_sub(1)) * self.per_page
    }

    pub fn limit(&self) -> u64 {
        self.per_page.min(MAX_PER_PAGE)
    }
}

const MAX_PER_PAGE: u64 = 100;

/// Paginated response wrapper.
#[derive(Debug, Clone, Serialize)]
pub struct PaginatedResponse<T: Serialize> {
    pub data: Vec<T>,
    pub meta: PaginationMeta,
}

#[derive(Debug, Clone, Serialize)]
pub struct PaginationMeta {
    pub page: u64,
    pub per_page: u64,
    pub total: u64,
    pub total_pages: u64,
}

impl PaginationMeta {
    pub fn new(page: u64, per_page: u64, total: u64) -> Self {
        let total_pages = if total == 0 {
            0
        } else {
            total.div_ceil(per_page)
        };
        Self {
            page,
            per_page,
            total,
            total_pages,
        }
    }
}
