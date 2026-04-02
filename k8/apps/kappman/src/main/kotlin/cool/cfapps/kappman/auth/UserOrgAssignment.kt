package cool.cfapps.kappman.auth

import jakarta.persistence.*

@Entity
@Table(
    name = "user_org_assignments",
    uniqueConstraints = [UniqueConstraint(columnNames = ["user_id", "org_guid"])]
)
class UserOrgAssignment(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "user_id", nullable = false)
    var user: User? = null,

    @Column(name = "org_guid", nullable = false)
    var orgGuid: String = ""
)
