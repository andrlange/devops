document.addEventListener('DOMContentLoaded', function () {
    // Generic live filter: searches data-filter-text on filterable items
    document.querySelectorAll('[data-live-filter]').forEach(function (input) {
        var targetId = input.getAttribute('data-live-filter');
        var container = document.getElementById(targetId);
        if (!container) return;

        input.addEventListener('input', function () {
            var query = input.value.toLowerCase().trim();
            container.querySelectorAll('[data-filter-text]').forEach(function (item) {
                var text = item.getAttribute('data-filter-text').toLowerCase();
                item.style.display = text.includes(query) ? '' : 'none';
            });
            // Update count badge if present
            var countEl = document.getElementById(targetId + '-count');
            if (countEl) {
                var visible = container.querySelectorAll('[data-filter-text]:not([style*="display: none"])').length;
                countEl.textContent = visible;
            }
        });
    });

    // Type filter tabs for pets
    document.querySelectorAll('[data-type-filter]').forEach(function (tab) {
        tab.addEventListener('click', function (e) {
            e.preventDefault();
            var type = tab.getAttribute('data-type-filter').toLowerCase();
            var container = document.getElementById('filterable-list');
            if (!container) return;

            // Update active tab
            document.querySelectorAll('[data-type-filter]').forEach(function (t) {
                t.classList.remove('active');
            });
            tab.classList.add('active');

            container.querySelectorAll('[data-pet-type]').forEach(function (item) {
                if (type === 'all') {
                    item.style.display = '';
                } else if (type === 'rodents') {
                    var petType = item.getAttribute('data-pet-type').toLowerCase();
                    item.style.display = (petType === 'hamster' || petType === 'guinea pig' || petType === 'rabbit') ? '' : 'none';
                } else if (type === 'other') {
                    var petType = item.getAttribute('data-pet-type').toLowerCase();
                    item.style.display = (petType === 'turtle' || petType === 'snake') ? '' : 'none';
                } else {
                    var petType = item.getAttribute('data-pet-type').toLowerCase();
                    item.style.display = petType === type ? '' : 'none';
                }
            });
        });
    });
});
