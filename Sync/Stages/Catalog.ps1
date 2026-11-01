# Every stage in canonical order. Requires = hard dependency (must have synced before, or be in
# the same run). After = ordering only, when both are in the same run. Implemented stages attach
# their runner with Set-SyncStageRunner from their own file.
$catalog = @(
    @{ Name = 'companies'; Description = 'IT Glue organizations -> Hudu companies' }
    @{ Name = 'locations'; Description = 'IT Glue locations -> Hudu Locations layout assets'; Requires = @('companies') }
    @{ Name = 'contacts'; Description = 'IT Glue contacts -> Hudu People layout assets'; Requires = @('companies'); After = @('locations') }
    @{ Name = 'websites'; Description = 'IT Glue domains -> Hudu websites'; Requires = @('companies') }
    @{ Name = 'configurations'; Description = 'IT Glue configurations -> Hudu configuration assets'; Requires = @('companies'); After = @('locations', 'contacts') }
    @{ Name = 'networks'; Description = 'Configuration interfaces -> Hudu IPAM networks/addresses'; Requires = @('companies', 'configurations') }
    @{ Name = 'flexlayouts'; Description = 'IT Glue flexible asset types -> Hudu asset layouts' }
    @{ Name = 'flexassets'; Description = 'IT Glue flexible assets -> Hudu assets'; Requires = @('companies', 'flexlayouts'); After = @('locations', 'contacts', 'configurations') }
    @{ Name = 'articles'; Description = 'IT Glue documents -> Hudu knowledge base articles'; Requires = @('companies') }
    @{ Name = 'passwordfolders'; Description = 'IT Glue password folders -> Hudu password folders (JWT)'; Requires = @('companies') }
    @{ Name = 'passwords'; Description = 'IT Glue passwords -> Hudu passwords'; Requires = @('companies'); After = @('passwordfolders', 'websites', 'configurations', 'flexassets', 'contacts', 'locations') }
    @{ Name = 'checklists'; Description = 'IT Glue checklists -> Hudu processes (JWT)'; Requires = @('companies') }
    @{ Name = 'relations'; Description = 'Related items between synced records'; Requires = @('companies'); After = @('locations', 'contacts', 'websites', 'configurations', 'flexassets', 'articles', 'passwords') }
    @{ Name = 'urlrewrite'; Description = 'Rewrite IT Glue links in synced content to Hudu links'; Requires = @('companies'); After = @('locations', 'contacts', 'websites', 'configurations', 'flexassets', 'articles', 'passwords', 'relations') }
)
foreach ($s in $catalog) {
    Register-SyncStage -Name $s.Name -Description $s.Description -Requires @($s.Requires | Where-Object { $_ }) -After @($s.After | Where-Object { $_ })
}
