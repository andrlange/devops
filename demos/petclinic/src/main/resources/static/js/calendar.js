document.addEventListener('DOMContentLoaded', function() {
    // Month navigation with keyboard arrows
    document.addEventListener('keydown', function(e) {
        const prevLink = document.querySelector('.calendar-nav-prev');
        const nextLink = document.querySelector('.calendar-nav-next');
        if (e.key === 'ArrowLeft' && prevLink) prevLink.click();
        if (e.key === 'ArrowRight' && nextLink) nextLink.click();
    });
});
