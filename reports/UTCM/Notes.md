## Microsoft Graph UTCM API Summary for Intune Team Lead

Microsoft's new **Unified Tenant Configuration Management (UTCM)** APIs provide native drift monitoring and configuration management across Microsoft 365 workloads, including Intune. This is currently in **beta preview** and offers a Graph API-based alternative to solutions like Microsoft 365 DSC. [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)

### What It Does
- **Baseline creation**: Capture snapshots of current tenant configuration settings as a "desired state" foundation [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)
- **Automated monitoring**: Continuously monitor for configuration drift across Intune, Entra, Exchange, Teams, Defender, and Purview [learn.microsoft](https://learn.microsoft.com/en-us/graph/utcm-supported-resourcetypes)
- **Drift detection**: Identify when settings deviate from the approved baseline, showing what changed and when [blog.admindroid](https://blog.admindroid.com/tenant-configuration-drift-monitoring-in-m365-using-utcm/)

### Key Components
- **Snapshot APIs**: Extract current tenant configuration (baseline) for comparison [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)
- **Monitor APIs**: Create automated monitors that run every 6 hours to detect drift [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)
- **Drift APIs**: Review all active drifts and track resolution status [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)

### Critical Limitations
- **30 monitors maximum** per tenant [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)
- **Fixed 6-hour monitoring interval** (cannot be customized) [blog.admindroid](https://blog.admindroid.com/tenant-configuration-drift-monitoring-in-m365-using-utcm/)
- **800 resources per day** monitoring quota across all monitors (e.g., 20 transport rules + 30 conditional access policies = 50 resources × 4 cycles/day = 200 resources/day) [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)
- **20,000 resources per month** snapshot extraction limit [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)
- **7-day snapshot retention** before automatic deletion [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)
- Fixed drifts are deleted **30 days after resolution** [blog.admindroid](https://blog.admindroid.com/tenant-configuration-drift-monitoring-in-m365-using-utcm/)

### Prerequisites
- Add **UTCM service principal** to your tenant first (mandatory setup step) [blog.admindroid](https://blog.admindroid.com/tenant-configuration-drift-monitoring-in-m365-using-utcm/)
- Grant appropriate Microsoft Graph permissions [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)
- Acquire access token for API calls [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)

### Use Cases for Intune
- Monitor Intune compliance policies for unauthorized changes [blog.admindroid](https://blog.admindroid.com/tenant-configuration-drift-monitoring-in-m365-using-utcm/)
- Track configuration drift in device management settings [petri](https://petri.com/microsoft-graph-utcm-apis-configuration-drift/)
- Maintain security baselines across Windows/iOS/Android policies [blog.admindroid](https://blog.admindroid.com/tenant-configuration-drift-monitoring-in-m365-using-utcm/)
- Support audits and security reviews with configuration snapshots [petri](https://petri.com/microsoft-graph-utcm-apis-configuration-drift/)

### Important Notes
- Updating a monitor's baseline **deletes all previous monitoring results and drifts** for that monitor [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)
- APIs are **beta only** and subject to change; not recommended for production automation yet [learn.microsoft](https://learn.microsoft.com/en-us/graph/api/resources/unified-tenant-configuration-management-api-overview?view=graph-rest-beta)
- No automatic remediation—drift detection only; you resolve via admin centers [petri](https://petri.com/microsoft-graph-utcm-apis-configuration-drift/)